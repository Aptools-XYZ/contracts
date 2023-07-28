/// Steps:
/// 1. deposite_fee_for to deposit fee first for an account to create a key of a coin.
/// 2. call API to create a coin and then all the created coin will be saved into this factory.
/// 3. call withdraw to take all the tokens to the creator.
module coin_factory::airdropper {
    use std::signer;
    use std::vector;
    use std::timestamp;
    use std::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};

    use aptos_std::table_with_length::{Self as table, TableWithLength as Table};

    struct AccountCapability has key { signer_cap: SignerCapability } 

    struct Config has key {
        price: u64, // divide by 10000
        fee_collector: address,
        index: u64,
    }

    struct FeeStore<phantom X> has key{
        reserve: Coin<X>,
    }

    struct Airdrop<phantom X> has store {
        owner: address,
        reserve: Coin<X>,
        expire_at: u64, // 0 means never expire, and owner can never withdraw what's left.
        list: Table<address, u64>
    }

    struct Store<phantom X> has key {
        store: Table<u64, Airdrop<X>>,
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

    const ONE_DAY_IN_SECONDS: u64 = 60 * 60 * 24;

    fun init_module(coin_factory: &signer){
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_airdrop_seed");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        move_to(&resource_signer, Config {
            price: 10, // 0.1% of the fee.
            fee_collector: @fee_collector,
            index: 0
        });  
    }

    public entry fun deposit<X>(account: &signer, target_addresses: vector<address>, amounts: vector<u64>, expire_at: u64)
        acquires Config, AccountCapability, FeeStore, Store, OwnerAirdrops
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
        if(!exists<FeeStore<X>>(resource_address))
            move_to(&resource_account, FeeStore<X>{
                reserve: coin::zero<X>(),
            });
        let fee_store = borrow_global_mut<FeeStore<X>>(resource_address);
        let fee_amount = total_amount * price  / 10000;

        // take all the coins out from the payee
        let coins = coin::withdraw<X>(account, total_amount + fee_amount);

        // pay fee to collector.
        let fee_coins = coin::extract<X>(&mut coins, fee_amount);
        coin::merge<X>(&mut fee_store.reserve, fee_coins);

        // initialize the airdrop
        let config = borrow_global_mut<Config>(resource_address);
        let index = config.index;
        // increase the index.
        config.index = index + 1;

        // register first time.
        if(!exists<Store<X>>(resource_address))
            move_to(&resource_account, Store<X>{
                store: table::new<u64, Airdrop<X>>(),
            });

        if(!exists<OwnerAirdrops>(resource_address))
            move_to(&resource_account, OwnerAirdrops {
                airdrops: table::new<address, vector<u64>>()
            });

        let owner_airdrops = &mut borrow_global_mut<OwnerAirdrops>(resource_address).airdrops;
        let airdops = table::borrow_mut_with_default(owner_airdrops, signer::address_of(account), vector::empty<u64>());
        vector::push_back(airdops, index);

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        table::add(store, index, Airdrop<X>{
            owner: signer::address_of(account),
            reserve: coins,
            expire_at,
            list: build_list<X>(target_addresses, amounts)
        });
    }    

    public entry fun append<X>(account: &signer, target_addresses: vector<address>, amounts: vector<u64>, airdrop_index: u64)
        acquires Config, AccountCapability, FeeStore, Store
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        assert!(!vector::is_empty(&target_addresses), E_NO_ETNRIES);
        assert!(vector::length(&target_addresses) == vector::length(&amounts), E_AMOUNTS_NE_ADDRESSES);
        assert!(exists<Store<X>>(resource_address), E_AIRDRP_NO_EXISTS);

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        assert!(table::contains(store, airdrop_index), E_AIRDRP_NO_EXISTS);

        let airdrop = table::borrow_mut(store, airdrop_index);
        assert!(airdrop.owner == signer::address_of(account), E_NO_PERMISSION);
        assert!(airdrop.expire_at == 0 || airdrop.expire_at > timestamp::now_seconds(), E_AIRDROP_EXPIRED);

        let (total_amount, index) = (0, vector::length(&amounts));
        while(index > 0){
            total_amount = total_amount + *vector::borrow(&amounts, index - 1);
            index = index -1;
        };

        // lets take the fee
        let price = get_price();
        if(!exists<FeeStore<X>>(resource_address))
            move_to(&resource_account, FeeStore<X>{
                reserve: coin::zero<X>(),
            });
        let fee_store = borrow_global_mut<FeeStore<X>>(resource_address);
        let fee_amount = total_amount * price  / 10000;

        // take all the coins out from the payee
        let coins = coin::withdraw<X>(account, total_amount + fee_amount);

        // pay fee to collector.
        let fee_coins = coin::extract<X>(&mut coins, fee_amount);
        coin::merge(&mut fee_store.reserve, fee_coins);
        coin::merge(&mut airdrop.reserve, coins);

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

    public fun get_last_index(): u64 acquires Config ,AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        borrow_global<Config>(resource_address).index - 1
    }

    public entry fun claim<X>(account:&signer, index: u64)
        acquires AccountCapability, Store
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        assert!(table::contains<u64, Airdrop<X>>(store, index), E_NO_AIRDROP);

        let airdrop = table::borrow_mut<u64, Airdrop<X>>(store, index);
        assert!(table::contains<address, u64>(&airdrop.list, account_address), E_NO_QUALIFIED);
        assert!(airdrop.expire_at == 0 || airdrop.expire_at >= timestamp::now_seconds(), E_AIRDROP_EXPIRED);

        let amount_to_claim = *table::borrow<address, u64>(&airdrop.list, account_address);
        let coins = coin::extract(&mut airdrop.reserve, amount_to_claim);
        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);

        // deposit coin.
        coin::deposit<X>(account_address, coins);

        // remove entry after claim.
        table::remove<address, u64>(&mut airdrop.list, account_address);
    }

    public entry fun withdraw<X>(account: &signer, index: u64)
        acquires AccountCapability, Store
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        assert!(table::contains<u64, Airdrop<X>>(store, index), E_NO_AIRDROP);

        let airdrop = table::borrow_mut<u64, Airdrop<X>>(store, index);
        assert!(airdrop.owner == account_address, E_NO_OWNER);
        assert!(airdrop.expire_at > 0 && airdrop.expire_at < timestamp::now_seconds(), E_AIRDROP_NOT_EXPIRED);

        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);   
        
        let balance = coin::value(&airdrop.reserve);
        let coins_left = coin::extract(&mut airdrop.reserve, balance);
        coin::deposit<X>(account_address, coins_left);  

        // clear from store
        let Airdrop{owner:_, expire_at:_, reserve:_, list:_} = airdrop;
    }

    public entry fun set_fee_collector(account: &signer, new_fee_collector: address) acquires AccountCapability, Config{
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let config = borrow_global_mut<Config>(resource_address);
        assert!(signer::address_of(account) == config.fee_collector, E_NO_PERMISSION);

        config.fee_collector = new_fee_collector;
    }

    public entry fun set_price(account: &signer, new_fee_without_decimals: u8) acquires Config, AccountCapability{
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let config = borrow_global_mut<Config>(resource_address);
        assert!(signer::address_of(account) == config.fee_collector, E_NO_PERMISSION);
        config.price = (new_fee_without_decimals as u64);
    }  

    public entry fun get_price(): u64 acquires Config, AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        borrow_global<Config>(resource_address).price
    }

    public entry fun collect_fee<X>(account: &signer, amount: u64) acquires Config, FeeStore, AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let config = borrow_global<Config>(resource_address);
        let fee_collector = config.fee_collector;

        assert!(signer::address_of(account) == fee_collector, E_NO_PERMISSION);
        assert!(amount>0, E_INVALID_PARAMETER);
        
        let fee_store = borrow_global_mut<FeeStore<X>>(resource_address);
        let balance = coin::value(&fee_store.reserve);
        assert!(balance >= amount, E_NO_BALANCE);
        let apt_withdraw = coin::extract(&mut fee_store.reserve, amount);
        coin::deposit(signer::address_of(account), apt_withdraw);
    }    

    #[test_only]
    use coin_factory::coin_helper::{USDC, create_admin_with_coins, mint};

    #[test_only]
    public fun setup_test(): (signer){
        account::create_account_for_test(@0x1);
        
        let admin = create_admin_with_coins();
        let usdc_decimals = (coin::decimals<USDC>() as u64);
        let usdc = mint<USDC>(&admin, 10000 * std::math64::pow(10, usdc_decimals));
        coin::register<USDC>(&admin);
        coin::deposit<USDC>(signer::address_of(&admin), usdc);

        admin
    }   

    #[test()]
    public entry fun test_happyflow() acquires Config, AccountCapability, FeeStore, Store, OwnerAirdrops{
        let admin = setup_test();
        init_module(&admin);

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