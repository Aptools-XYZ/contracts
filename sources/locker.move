module coin_factory::locker{
    use std::signer;
    use std::vector;
    use std::math64;
    use std::timestamp;
    use std::option::{Self, Option};
    use std::account::{Self, SignerCapability};
    use std::string::{utf8, String};

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::{AptosCoin};

    use coin_factory::utils;
    use coin_factory::dao_storage;
    use coin_factory::config;      

    use aptos_std::table_with_length::{Self as table, TableWithLength as Table};

    struct AccountCapability has key { signer_cap: SignerCapability } 

    struct LockInfo has drop, store, key, copy{
        owner: address,
        unlock_time: u64,
        locked_at: u64,     
        amount: u64,
        coin: String,
        withdrawn_at: Option<u64>,
    }

    struct Reserve<phantom X> has store {
        reserve: Coin<X>,
    }

    struct OwnerLocks has key {
        locks: Table<address, vector<u64>>,
    }

    struct Store<phantom X> has key {
        store: Table<u64, Reserve<X>>,
    }

    struct InfoStore has store, key {
        store: Table<u64, LockInfo>,
    }    

    struct FeeStore has key{
        reserve: Coin<AptosCoin>
    }

    const E_NO_PERMISSION: u64 = 0;
    const E_NO_BALANCE: u64 = 1;
    const E_INVALID_PARAMETER: u64 = 2;
    const E_NO_ETNRIES: u64 = 3;
    const E_AMOUNTS_NE_ADDRESSES: u64 = 4;
    const E_NO_LOCK: u64 = 5;
    const E_NO_QUALIFIED: u64 = 6;
    const E_INVALID_EXPIRY: u64 = 7;
    const E_LOCK_EXPIRED: u64 = 8;
    const E_LOCK_NOT_EXPIRED: u64 = 9;
    const E_NO_OWNER: u64 = 10;
    const E_AIRDRP_NO_EXISTS: u64 = 11;    

    const ONE_DAY_IN_SECONDS: u64 = 60 * 60 * 24;
    const CONFIG_PRICE: vector<u8> = b"PRICE";
    const CONFIG_INDEX: vector<u8> = b"INDEX";


    fun init_module(coin_factory: &signer){
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_locker_seed");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        config::set_v1(&resource_signer, utf8(CONFIG_PRICE), &(10 * math64::pow(10, 8))); // 10 APT
        config::set_v1(&resource_signer, utf8(CONFIG_INDEX), &0u64); 

        move_to(&resource_signer, FeeStore {
            reserve: coin::zero<AptosCoin>()
        });  

        move_to(&resource_signer, OwnerLocks {
            locks: table::new<address, vector<u64>>()
        });    

        move_to(&resource_signer, InfoStore {
            store: table::new<u64, LockInfo>(),
        });   
    }

    public entry fun set_price(account: &signer, new_fee_without_decimals: u8) acquires AccountCapability{
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);

        assert!(signer::address_of(account) == dao_storage::get_fee_collector(), E_NO_PERMISSION);
        config::set_v1(&resource_account, utf8(CONFIG_PRICE), &(new_fee_without_decimals as u64));
    }  

    fun get_index():u64 acquires AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        config::read_u64_v1(resource_address, &utf8(CONFIG_INDEX))
    }

    fun get_price():u64 acquires AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        config::read_u64_v1(resource_address, &utf8(CONFIG_PRICE))
    } 

    public fun get_last_index(): u64 acquires AccountCapability {
        get_index() - 1
    }     

    public fun get_lock_ids(addr: address): vector<u64> acquires AccountCapability, OwnerLocks
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);     

        let locks = & borrow_global<OwnerLocks>(resource_address).locks;  
        let ids = table::borrow(locks, addr);

        *ids
    }

    public fun get_lock_info<X>(index: u64) : LockInfo
        acquires InfoStore, AccountCapability 
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);
        let store = & borrow_global<InfoStore>(resource_address).store;

        assert!(table::contains<u64, LockInfo>(store, index), E_NO_LOCK);
        *table::borrow<u64, LockInfo>(store, index)    
    }

    public entry fun lock<X>(account: &signer, amount: u64, unlock_time: u64)
        acquires AccountCapability, FeeStore, OwnerLocks, Store, InfoStore
    {

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        assert!(amount > 0, E_INVALID_PARAMETER);
        assert!(unlock_time > timestamp::now_seconds() + ONE_DAY_IN_SECONDS, E_INVALID_EXPIRY);

        // lets take the fee
        let fee_amount = get_price();
        let fee_store = borrow_global_mut<FeeStore>(resource_address);
        // pay fee to collector.
        let fee_coins = coin::withdraw<AptosCoin>(account, fee_amount);
        coin::merge(&mut fee_store.reserve, fee_coins);

        // initialize the lock
        let index = get_index();
        // increase the index.
        config::set_v1(&resource_account, utf8(CONFIG_INDEX), &(index + 1));

        // register first time.
        if(!exists<Store<X>>(resource_address))
            move_to(&resource_account, Store<X>{
                store: table::new<u64, Reserve<X>>(),
            });

        let locks = &mut borrow_global_mut<OwnerLocks>(resource_address).locks;
        let lock = table::borrow_mut_with_default(locks, signer::address_of(account), vector::empty<u64>());
        vector::push_back(lock, index);

        let coins = coin::withdraw<X>(account, amount);
        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        table::add(store, index, Reserve<X>{
            reserve: coins,
        });

        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        table::add(store, index, LockInfo{
            owner: signer::address_of(account),
            unlock_time,
            locked_at: timestamp::now_seconds(),
            coin: utils::type_to_string<X>(),
            amount,
            withdrawn_at: option::none<u64>(),
        })
    }

    public entry fun withdraw<X>(account: &signer, index: u64)
        acquires AccountCapability, Store, InfoStore
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let reserve_store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        assert!(table::contains<u64, Reserve<X>>(reserve_store, index), E_NO_LOCK);

        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        let reserve = table::borrow_mut<u64, Reserve<X>>(reserve_store, index);

        let lock_info = table::borrow_mut<u64, LockInfo>(store, index);

        assert!(lock_info.owner == account_address, E_NO_OWNER);
        assert!(lock_info.unlock_time <= timestamp::now_seconds(), E_LOCK_NOT_EXPIRED);

        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);   
        
        let coins_left = coin::extract_all(&mut reserve.reserve);
        coin::deposit<X>(account_address, coins_left); 

        // clear from store
        let Reserve<X>{reserve:_} = reserve;

        // update eth
        lock_info.amount = 0;
        lock_info.withdrawn_at = option::some(timestamp::now_seconds());
    }  

    public entry fun transfer_ownership<X>(account: &signer, new_owner: address, index: u64)
        acquires AccountCapability, FeeStore, OwnerLocks, InfoStore{
            transfer_owenrship<X>(account, new_owner, index);
    }  

    public entry fun transfer_owenrship<X>(account: &signer, new_owner: address, index: u64)
        acquires AccountCapability, FeeStore, OwnerLocks, InfoStore
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        assert!(table::contains<u64, LockInfo>(store, index), E_NO_LOCK);

        let lock_info = table::borrow_mut<u64, LockInfo>(store, index);
        assert!(lock_info.owner == account_address, E_NO_OWNER);

        // lets take the fee
        let fee_amount = get_price() / 10; //transfer takes 1/10 of the fee. 
        let fee_store = borrow_global_mut<FeeStore>(resource_address);
        // pay fee to collector.
        let fee_coins = coin::withdraw<AptosCoin>(account, fee_amount);
        coin::merge(&mut fee_store.reserve, fee_coins);  

        // now lets change the ownership
        // first store owner.
        lock_info.owner = new_owner;

        // then the ownerLocks
        let locks = &mut borrow_global_mut<OwnerLocks>(resource_address).locks;
        let owner_locks = table::borrow_mut(locks, account_address);
        let (i, length) = (0, vector::length(owner_locks));
        while(i < length){
            if(*vector::borrow(owner_locks, i) == index){
                vector::swap(owner_locks, i, length - 1);
                vector::pop_back(owner_locks);
                break
            };
            i = i + 1;
        };

        if(table::contains(locks, new_owner)){
            // merge
            let existing = table::borrow_mut(locks, new_owner);
            vector::push_back(existing, index);
        } else {
           // add
           table::add(locks, new_owner, vector<u64>[index]); 
        }
    }

    #[test_only]
    use coin_factory::coin_helper::{USDC, create_admin_with_coins, mint};

    #[test_only]
    public fun setup_test(): (signer){
        let sys = account::create_account_for_test(@0x1);
        
        let admin = create_admin_with_coins();
        let usdc_decimals = (coin::decimals<USDC>() as u64);
        let usdc = mint<USDC>(&admin, 10000 * std::math64::pow(10, usdc_decimals));

        coin::register<USDC>(&admin);

        coin::deposit<USDC>(signer::address_of(&admin), usdc);
        let (burn_cap, mint_cap) = aptos_framework::aptos_coin::initialize_for_test(&sys);  
        coin::destroy_burn_cap(burn_cap);   

        coin::register<AptosCoin>(&admin);
        let apts = coin::mint<AptosCoin>(10000 * math64::pow(10, 8), &mint_cap);
        coin::deposit(signer::address_of(&admin), apts);

        coin::destroy_mint_cap(mint_cap);  

        timestamp::set_time_has_started_for_testing(&sys);

        admin
    }   

    #[test()]
    public entry fun test_lock() : signer
    acquires AccountCapability, FeeStore, Store, InfoStore, OwnerLocks
    {
        let admin = setup_test();
        let admin_address = signer::address_of(&admin);
        init_module(&admin);    

        let prev_balance = coin::balance<AptosCoin>(admin_address);

        lock<USDC>(&admin, 10000 * math64::pow(10, 6), timestamp::now_seconds() + ONE_DAY_IN_SECONDS * 2);

        let now_balance = coin::balance<AptosCoin>(admin_address);
        assert!(prev_balance - now_balance == get_price(), 0);

        let index = get_last_index();
        let info = get_lock_info<USDC>(index);

        assert!(info.owner == signer::address_of(&admin), 1);
        assert!(info.amount == 10000 * math64::pow(10, 6), 2);
        assert!(info.locked_at == timestamp::now_seconds(), 3);
        assert!(info.unlock_time == timestamp::now_seconds()+ ONE_DAY_IN_SECONDS * 2, 3 );
        assert!(vector::length(&get_lock_ids(admin_address)) == 1, 4);

        admin
    }

    #[test()]
    #[expected_failure(abort_code = 0x9)]
    public entry fun test_withdraw_fail() 
        acquires AccountCapability, FeeStore, Store, OwnerLocks, InfoStore
    {
        let admin = test_lock();
        withdraw<USDC>(&admin, get_last_index());
    }

    #[test()]
    public entry fun test_withdraw() 
        acquires AccountCapability, FeeStore, Store, OwnerLocks, InfoStore
    {
        let admin = test_lock();
        let index = get_last_index();
        let admin_address = signer::address_of(&admin);

        let info = get_lock_info<USDC>(index);
        // std::debug::print(&info);

        let prev_balance = coin::balance<USDC>(admin_address);
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds()+ ONE_DAY_IN_SECONDS * 2);
        withdraw<USDC>(&admin, index);
        let now_balance = coin::balance<USDC>(admin_address);

        assert!(prev_balance == now_balance - info.amount, 0);
    }  

    #[test()]
    public entry fun test_transfer() 
        acquires AccountCapability, FeeStore, Store, OwnerLocks, InfoStore
    {  
        let admin = test_lock();
        let index = get_last_index();
        let admin_address = signer::address_of(&admin);

        let admin2 = account::create_account_for_test(@0x345);

        let prev_balance = coin::balance<AptosCoin>(admin_address);
        transfer_owenrship<USDC>(&admin, signer::address_of(&admin2), index);
        let now_balance = coin::balance<AptosCoin>(admin_address);
        assert!(prev_balance == now_balance + get_price() / 10, 0);

        assert!(vector::length(&get_lock_ids(admin_address)) == 0, 1);

        let info = get_lock_info<USDC>(index);
        assert!(info.owner == signer::address_of(&admin2), 2);
        assert!(vector::length(&get_lock_ids(signer::address_of(&admin2))) == 1, 1);
    }
}