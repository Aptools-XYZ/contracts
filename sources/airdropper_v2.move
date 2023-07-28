/// Steps:
/// 1. deposite_fee_for to deposit fee first for an account to create a key of a coin.
/// 2. call API to create a coin and then all the created coin will be saved into this factory.
/// 3. call withdraw to take all the tokens to the creator.
module coin_factory::airdropper_v2 {
    use std::signer;
    use std::vector;
    use std::timestamp;
    use std::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};
    use std::option::{Self, Option};
    use std::string::{utf8, String};

    use aptos_std::table_with_length::{Self as table, TableWithLength as Table};

    use coin_factory::utils;
    use coin_factory::dao_storage;  
    use coin_factory::config;  

    struct AccountCapability has key { signer_cap: SignerCapability } 

    struct AirdropInfo has store, key{ 
        owner: address,
        expire_at: u64, // 0 means never expire, and owner can never withdraw what's left.
        list: Table<address, u64>,
        coin: String,
        created_at: u64,
        amount: u64,
        withdrawn_at: Option<u64>
    }

    struct Reserve<phantom X> has store {
        reserve: Coin<X>,
    }

    struct Store<phantom X> has key {
        store: Table<u64, Reserve<X>>,
    }

    struct InfoStore has key {
        store: Table<u64, AirdropInfo>,
    }    

    struct OwnerAirdrops has key {
        airdrops: Table<address, vector<u64>>,
    }

    const E_NO_PERMISSION: u64 = 0;
    const E_NO_BALANCE: u64 = 1;
    const E_INVALID_PARAMETER: u64 = 2;
    const E_NO_ETNRIES: u64 = 3;
    const E_AMOUNTS_NE_ADDRESSES: u64 = 4;
    const E_NO_AIRDROP: u64 = 5;
    const E_NO_QUALIFIED: u64 = 6;
    const E_INVALID_EXPIRY: u64 = 7;
    const E_AIRDROP_EXPIRED: u64 = 8;
    const E_AIRDROP_NOT_EXPIRED: u64 = 9;
    const E_NO_OWNER: u64 = 10;
    const E_AIRDRP_NO_EXISTS: u64 = 11;
    const E_ALREADY_WITHDRAWN: u64 = 12;

    const ONE_DAY_IN_SECONDS: u64 = 60 * 60 * 24;

    const CONFIG_PRICE: vector<u8> = b"PRICE";
    const CONFIG_INDEX: vector<u8> = b"INDEX";

    fun init_module(coin_factory: &signer){
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_airdrop_seed_v2");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        config::register(&resource_signer);
        config::set_v1(&resource_signer, utf8(CONFIG_PRICE), &10u64); // 0.1% of the fee.
        config::set_v1(&resource_signer, utf8(CONFIG_INDEX), &0u64); 

        move_to(&resource_signer, InfoStore {
            store: table::new<u64, AirdropInfo>(),
        });          
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

    public entry fun deposit<X>(account: &signer, target_addresses: vector<address>, amounts: vector<u64>, expire_at: u64)
        acquires AccountCapability, Store, OwnerAirdrops, InfoStore
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        assert!(!vector::is_empty(&target_addresses), E_NO_ETNRIES);
        assert!(vector::length(&target_addresses) == vector::length(&amounts), E_AMOUNTS_NE_ADDRESSES);
        assert!(expire_at ==0 || expire_at > timestamp::now_seconds() + ONE_DAY_IN_SECONDS, E_INVALID_EXPIRY);

        let (total_amount, index) = (0, vector::length(&amounts));
        while(index > 0){
            total_amount = total_amount + *vector::borrow(&amounts, index - 1);
            index = index -1;
        };

        // lets take the fee
        let price = get_price();

        let fee_amount = total_amount * price  / 10000;
        // take all the coins out from the payee
        let coins = coin::withdraw<X>(account, total_amount + fee_amount);

        dao_storage::deposit<X>(coin::extract(&mut coins, fee_amount));

        // initialize the airdrop
        let index = get_index();
        // increase the index.
        config::set_v1(&resource_account, utf8(CONFIG_INDEX), &(index + 1));

        // register first time.
        if(!exists<Store<X>>(resource_address))
            move_to(&resource_account, Store<X>{
                store: table::new<u64, Reserve<X>>(),
            });

        if(!exists<OwnerAirdrops>(resource_address))
            move_to(&resource_account, OwnerAirdrops {
                airdrops: table::new<address, vector<u64>>()
            });

        let owner_airdrops = &mut borrow_global_mut<OwnerAirdrops>(resource_address).airdrops;
        let airdops = table::borrow_mut_with_default(owner_airdrops, signer::address_of(account), vector::empty<u64>());
        vector::push_back(airdops, index);

        let info_store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        table::add(info_store, index, AirdropInfo {
            owner: signer::address_of(account),
            expire_at,
            created_at: timestamp::now_seconds(),
            amount: coin::value(&coins),
            list: build_list<X>(target_addresses, amounts),
            coin: utils::type_to_string<X>(),
            withdrawn_at: option::none<u64>(),
        });

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        table::add(store, index, Reserve<X>{
            reserve: coins,
        });
    }    

    public entry fun append<X>(account: &signer, target_addresses: vector<address>, amounts: vector<u64>, airdrop_index: u64)
        acquires  AccountCapability, Store, InfoStore
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        assert!(!vector::is_empty(&target_addresses), E_NO_ETNRIES);
        assert!(vector::length(&target_addresses) == vector::length(&amounts), E_AMOUNTS_NE_ADDRESSES);
        assert!(exists<Store<X>>(resource_address), E_AIRDRP_NO_EXISTS);

        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        assert!(table::contains(store, airdrop_index), E_AIRDRP_NO_EXISTS);

        let airdrop = table::borrow_mut(store, airdrop_index);
        assert!(airdrop.owner == signer::address_of(account), E_NO_PERMISSION);
        assert!(airdrop.expire_at == 0 || airdrop.expire_at > timestamp::now_seconds(), E_AIRDROP_EXPIRED);

        let (total_amount, index) = (0, vector::length(&amounts));
        while(index > 0){
            total_amount = total_amount + *vector::borrow(&amounts, index - 1);
            index = index -1;
        };

        airdrop.amount = airdrop.amount + total_amount;
        // lets take the fee
        let price = get_price();
        let fee_amount = total_amount * price  / 10000;
        // take all the coins out from the payee
        let coins = coin::withdraw<X>(account, total_amount + fee_amount);
        dao_storage::deposit<X>(coin::extract(&mut coins, fee_amount));

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        let reserve = table::borrow_mut(store, index);
        coin::merge(&mut reserve.reserve, coins);

        let list = &mut airdrop.list;
        let index = vector::length(&target_addresses);

        while(index > 0) {
            let address = *vector::borrow(&target_addresses, index - 1);
            let amount = *vector::borrow(&amounts, index - 1);

            if(!table::contains(list, address)){
                table::add(list, address, amount);
            }
            else {
                let existing_amount = *table::borrow(list, address);
                table::upsert(list, address, existing_amount +  amount);
            };

            index = index - 1;
        };
    }

    fun build_list<X>(target_addresses: vector<address>, amounts: vector<u64>): Table<address, u64>{
        let list = table::new<address, u64>();
        let index = vector::length(&target_addresses);

        while(index > 0) {
            let address = *vector::borrow(&target_addresses, index - 1);
            let amount = *vector::borrow(&amounts, index - 1);

            table::add(&mut list, address, amount);
            index = index - 1;
        };

        list
    }

    #[test_only]
    public fun get_airdrops_by_owner(account: &signer): vector<u64> 
        acquires AccountCapability, OwnerAirdrops
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);   

        let owner_airdrops = & borrow_global<OwnerAirdrops>(resource_address).airdrops;
        *table::borrow(owner_airdrops, account_address)
    }

    public fun get_last_index(): u64 acquires AccountCapability {
        get_index() - 1
    }

    public entry fun claim<X>(account:&signer, index: u64)
        acquires AccountCapability, Store, InfoStore
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        assert!(table::contains<u64, AirdropInfo>(store, index), E_NO_AIRDROP);

        let airdrop = table::borrow_mut<u64, AirdropInfo>(store, index);
        assert!(option::is_none(& airdrop.withdrawn_at), E_ALREADY_WITHDRAWN);
        assert!(table::contains<address, u64>(&airdrop.list, account_address), E_NO_QUALIFIED);
        assert!(airdrop.expire_at == 0 || airdrop.expire_at >= timestamp::now_seconds(), E_AIRDROP_EXPIRED);
        // assert!(option::ha)

        let amount_to_claim = *table::borrow<address, u64>(&airdrop.list, account_address);

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        let reserve = table::borrow_mut(store, index);

        let coins = coin::extract(&mut reserve.reserve, amount_to_claim);
        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);

        // deposit coin.
        coin::deposit<X>(account_address, coins);

        // remove entry after claim.
        table::remove<address, u64>(&mut airdrop.list, account_address);
    }

    public entry fun withdraw<X>(account: &signer, index: u64)
        acquires AccountCapability, Store, InfoStore
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        assert!(table::contains<u64, AirdropInfo>(store, index), E_NO_AIRDROP);

        let airdrop = table::borrow_mut<u64, AirdropInfo>(store, index);
        assert!(airdrop.owner == account_address, E_NO_OWNER);
        assert!(airdrop.expire_at > 0 && airdrop.expire_at < timestamp::now_seconds(), E_AIRDROP_NOT_EXPIRED);

        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);   
        
        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        let reserve = table::borrow_mut(store, index);
        let coins_left = coin::extract_all(&mut reserve.reserve);
        coin::deposit<X>(account_address, coins_left);  

        // clear from store
        let Reserve<X>{ reserve:_ } = reserve;

        // update eth
        airdrop.amount = 0;
        airdrop.withdrawn_at = option::some(timestamp::now_seconds());        
    }

    public entry fun set_price(account: &signer, new_fee_without_decimals: u8) acquires AccountCapability{
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);

        assert!(signer::address_of(account) == dao_storage::get_fee_collector(), E_NO_PERMISSION);
        config::set_v1(&resource_account, utf8(CONFIG_PRICE), &(new_fee_without_decimals as u64));
    }  

    #[test_only]
    use coin_factory::coin_helper::{USDC, create_admin_with_coins, mint};

    #[test_only]
    public fun setup_test(): (signer){
        let sys = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&sys);
        
        let admin = create_admin_with_coins();
        let usdc_decimals = (coin::decimals<USDC>() as u64);
        let usdc = mint<USDC>(&admin, 10000 * std::math64::pow(10, usdc_decimals));
        coin::register<USDC>(&admin);
        coin::deposit<USDC>(signer::address_of(&admin), usdc);

        admin
    }   

    #[test()]
    public entry fun test__airdrop_happyflow() 
        acquires AccountCapability, Store, OwnerAirdrops, InfoStore
    {
        let admin = setup_test();
        init_module(&admin);
        dao_storage::init_module_for_test(&admin);

        let addresses = vector<address>[@0x100, @0x101, @0x102, @0x103, @0x104, @0x105, @0x106];
        let amounts = vector<u64>[
            100 * std::math64::pow(10, 6), 
            101* std::math64::pow(10, 6), 
            102* std::math64::pow(10, 6),
            103* std::math64::pow(10, 6),
            104* std::math64::pow(10, 6),
            105* std::math64::pow(10, 6),
            106* std::math64::pow(10, 6)
        ];
        let users = vector::empty<signer>();
        let expire_at = 0;

        let index = 0;
        while(index < vector::length(&mut addresses)){
            let user = account::create_account_for_test(*vector::borrow(&addresses, index ));
            vector::push_back(&mut users, user);
            index = index + 1;
        };

        deposit<USDC>(&admin, addresses, amounts, expire_at);
        let airdrop_index = get_last_index();
        assert!(vector::length(&get_airdrops_by_owner(&admin)) == 1, 8);

        let subtotal = (100+101+102+103+104+105+106) * std::math64::pow(10, 6);
        let inital_balance = 10000 * std::math64::pow(10, 6);
        let fee = get_price() * subtotal / 10000;
        let balance = coin::balance<USDC>(signer::address_of(&admin));

        assert!(balance == inital_balance - subtotal - fee, 0);

        let index = 0;
        while(index < vector::length(&mut addresses)){
            let user = vector::borrow(&users, index);
            claim<USDC>(user, airdrop_index);

            let expected_amount = *vector::borrow(&amounts, index);
            let actual_amount = coin::balance<USDC>(signer::address_of(user));

            std::debug::print(&actual_amount);
            assert!(expected_amount == actual_amount, 1);

            index = index + 1;
        };

        // append to the same airdrop so users should be able to claim again.
        append<USDC>(&admin, addresses, amounts, airdrop_index);
        let index = 0;
        while(index < vector::length(&mut addresses)){
            let user = vector::borrow(&users, index);
            claim<USDC>(user, airdrop_index);

            let expected_amount = *vector::borrow(&amounts, index);
            let actual_amount = coin::balance<USDC>(signer::address_of(user));

            std::debug::print(&actual_amount);
            assert!(expected_amount * 2 == actual_amount, 1); // twice

            index = index + 1;
        };        

        deposit<USDC>(&admin, addresses, amounts, expire_at);
        let airdrop_index2 = get_last_index();
        std::debug::print(&airdrop_index2);
        assert!(airdrop_index != airdrop_index2, 3);
        assert!(vector::length(&get_airdrops_by_owner(&admin)) == 2, 8);
    }
}