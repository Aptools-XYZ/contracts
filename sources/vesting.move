module coin_factory::vesting {
    use std::account::{Self, SignerCapability};
    use std::signer;
    use std::vector;
    use std::timestamp;    
    use std::math64;
    use std::string::{utf8, String};  
    use std::option::{Self, Option};

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;

    use coin_factory::utils;
    use coin_factory::dao_storage;  
    use coin_factory::config;     

    use aptos_std::table_with_length::{Self as table, TableWithLength as Table};

    struct AccountCapability has key { signer_cap: SignerCapability }  

    struct VestingItem has store, key {
        cliff: u64,
        total: u64,
        claimed: u64,
    }

    struct VestingInfo has store, key{ 
        owner: address,
        from_seconds: u64, 
        to_seconds: u64, 
        list: Table<address, VestingItem>,
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
        store: Table<u64, VestingInfo>,
    }    

    struct OwnerVestings has key {
        vestings: Table<address, vector<u64>>,
    }    

    const E_NO_PERMISSION: u64 = 0;
    const E_NO_BALANCE: u64 = 1;
    const E_INVALID_PARAMETER: u64 = 2;
    const E_NO_ETNRIES: u64 = 3;
    const E_AMOUNTS_NE_ADDRESSES: u64 = 4;
    const E_NO_VESTING: u64 = 5;
    const E_NO_QUALIFIED: u64 = 6;
    const E_INVALID_FROM: u64 = 7;
    const E_NO_OWNER: u64 = 10;
    const E_VESTING_NO_EXISTS: u64 = 11;
    const E_ALREADY_WITHDRAWN: u64 = 12;
    const E_INVALID_TO: u64 = 13;
    const E_INVALID_CLIFFS: u64 = 14;
    const E_SIILL_IN_CLIFF: u64 = 15;
    const E_NOTHING_TO_CLAIM: u64 = 16;

    const ONE_DAY_IN_SECONDS: u64 = 60 * 60 * 24;    

    const CONFIG_PRICE: vector<u8> = b"PRICE";
    const CONFIG_INDEX: vector<u8> = b"INDEX";     

    fun init_module(coin_factory: &signer){
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_vesting_seed");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        config::register(&resource_signer);
        config::set_v1(&resource_signer, utf8(CONFIG_PRICE), &(5 * math64::pow(10, 8))); // 5 APT for vesting.
        config::set_v1(&resource_signer, utf8(CONFIG_INDEX), &0u64); 

        move_to(&resource_signer, InfoStore {
            store: table::new<u64, VestingInfo>(),
        });     
    }

    fun get_index():u64 acquires AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        config::read_u64_v1(resource_address, &utf8(CONFIG_INDEX))
    }

    public fun get_last_index(): u64 acquires AccountCapability {
        get_index() - 1
    }    

    fun get_price():u64 acquires AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        config::read_u64_v1(resource_address, &utf8(CONFIG_PRICE))
    }      

    public entry fun deposit<X>(account: &signer, target_addresses: vector<address>, amounts: vector<u64>, cliffs: vector<u64>, from_seconds: u64, to_seconds: u64)
        acquires AccountCapability, Store, OwnerVestings, InfoStore
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        assert!(!vector::is_empty(&target_addresses), E_NO_ETNRIES);
        assert!(vector::length(&target_addresses) == vector::length(&amounts), E_AMOUNTS_NE_ADDRESSES);
        assert!(vector::length(&amounts) == vector::length(&cliffs), E_AMOUNTS_NE_ADDRESSES);
        assert!(from_seconds >= timestamp::now_seconds(), E_INVALID_FROM);
        assert!(to_seconds > from_seconds + ONE_DAY_IN_SECONDS, E_INVALID_TO);

        let (total_amount, index) = (0, vector::length(&amounts));
        while(index > 0){
            total_amount = total_amount + *vector::borrow(&amounts, index - 1);
            index = index -1;
        };

        // lets take the fee
        let price = get_price();
        let fee_coins = coin::withdraw<AptosCoin>(account, price);
        dao_storage::deposit(fee_coins);

        // take all the coins out from the payee
        let coins = coin::withdraw<X>(account, total_amount);

        // initialize the vesting
        let index = get_index();
        // increase the index.
        config::set_v1(&resource_account, utf8(CONFIG_INDEX), &(index + 1));

        // register first time.
        if(!exists<Store<X>>(resource_address))
            move_to(&resource_account, Store<X>{
                store: table::new<u64, Reserve<X>>(),
            });

        if(!exists<OwnerVestings>(resource_address))
            move_to(&resource_account, OwnerVestings {
                vestings: table::new<address, vector<u64>>()
            });

        let owner_vestings = &mut borrow_global_mut<OwnerVestings>(resource_address).vestings;
        let vestings = table::borrow_mut_with_default(owner_vestings, signer::address_of(account), vector::empty<u64>());
        vector::push_back(vestings, index);

        let total_seconds = to_seconds - from_seconds;

        let info_store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        table::add(info_store, index, VestingInfo {
            owner: signer::address_of(account),
            from_seconds,
            to_seconds,
            created_at: timestamp::now_seconds(),
            amount: total_amount,
            list: build_list<X>(target_addresses, cliffs, amounts, total_seconds),
            coin: utils::type_to_string<X>(),
            withdrawn_at: option::none<u64>(),
        });

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        table::add(store, index, Reserve<X>{
            reserve: coins,
        });
    }    

    fun build_list<X>(
        target_addresses: 
        vector<address>, 
        cliffs: vector<u64>, 
        amounts: vector<u64>,
        total_seconds: u64
    ): Table<address, VestingItem>{
        let list = table::new<address, VestingItem>();
        let index = vector::length(&target_addresses);

        while(index > 0) {
            let address = *vector::borrow(&target_addresses, index - 1);
            let amount = *vector::borrow(&amounts, index - 1);
            let cliff = *vector::borrow(&cliffs, index - 1);

            assert!(cliff < total_seconds, E_INVALID_CLIFFS);
            table::add(&mut list, address, VestingItem {total: amount, cliff, claimed: 0});
            index = index - 1;
        };

        list
    }        

    public entry fun claim<X>(account:&signer, index: u64)
        acquires AccountCapability, Store, InfoStore
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        assert!(table::contains<u64, VestingInfo>(store, index), E_NO_VESTING);

        let vesting = table::borrow_mut<u64, VestingInfo>(store, index);
        assert!(option::is_none(& vesting.withdrawn_at), E_ALREADY_WITHDRAWN);
        assert!(table::contains<address, VestingItem>(&vesting.list, account_address), E_NO_QUALIFIED);

        let item = table::borrow_mut<address, VestingItem>(&mut vesting.list, account_address);
        assert!(timestamp::now_seconds() >= vesting.from_seconds + item.cliff, E_SIILL_IN_CLIFF);

        let total_seconds = vesting.to_seconds - vesting.from_seconds - item.cliff;
        let seconds_elapsed = math64::min(timestamp::now_seconds(), vesting.to_seconds) - vesting.from_seconds - item.cliff;
        let amount_to_claim = math64::min(item.total * seconds_elapsed / total_seconds, item.total) - item.claimed;
        assert!(amount_to_claim > 0, E_NOTHING_TO_CLAIM);
        item.claimed = item.claimed + amount_to_claim;

        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        let reserve = table::borrow_mut(store, index);
        let coins = coin::extract(&mut reserve.reserve, amount_to_claim);
        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);

        // deposit coin.
        coin::deposit<X>(account_address, coins);
    }

    public entry fun withdraw<X>(account: &signer, index: u64)
        acquires AccountCapability, Store, InfoStore
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        let store = &mut borrow_global_mut<InfoStore>(resource_address).store;
        assert!(table::contains<u64, VestingInfo>(store, index), E_NO_VESTING);

        let vesting = table::borrow_mut<u64, VestingInfo>(store, index);
        assert!(vesting.owner == account_address, E_NO_OWNER);
        assert!(option::is_none(& vesting.withdrawn_at), E_ALREADY_WITHDRAWN);        

        if(!coin::is_account_registered<X>(account_address))
            coin::register<X>(account);   
        
        let store = &mut borrow_global_mut<Store<X>>(resource_address).store;
        let reserve = table::borrow_mut(store, index);
        let coins_left = coin::extract_all(&mut reserve.reserve);
        coin::deposit<X>(account_address, coins_left);  

        // clear from store
        let Reserve<X>{ reserve:_ } = reserve;

        // update eth
        vesting.amount = 0;
        vesting.withdrawn_at = option::some(timestamp::now_seconds());        
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
    public fun get_vestings_by_owner(account: &signer): vector<u64> 
        acquires AccountCapability, OwnerVestings
    {
        let account_address = signer::address_of(account);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);   

        let owner_vestings = & borrow_global<OwnerVestings>(resource_address).vestings;
        *table::borrow(owner_vestings, account_address)
    }    

    #[test_only]
    public fun setup_test(): (signer){
        let sys = account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(&sys);
        
        let admin = create_admin_with_coins();
        let usdc_decimals = (coin::decimals<USDC>() as u64);
        let usdc = mint<USDC>(&admin, 10000 * std::math64::pow(10, usdc_decimals));
        coin::register<USDC>(&admin);
        coin::deposit<USDC>(signer::address_of(&admin), usdc);

        let (burn_cap, mint_cap) = aptos_framework::aptos_coin::initialize_for_test(&sys);  
        coin::destroy_burn_cap(burn_cap);           
        let apts = coin::mint<AptosCoin>(10000 * math64::pow(10, 8), &mint_cap);
        coin::register<AptosCoin>(&admin);
        coin::deposit(signer::address_of(&admin), apts);

        coin::destroy_mint_cap(mint_cap);          

        admin
    }   

    #[test()]
    public entry fun test_vesting_happyflow() 
        acquires AccountCapability, Store, OwnerVestings, InfoStore
    {
        let admin = setup_test();
        let admin_address = signer::address_of(&admin);
        init_module(&admin);
        dao_storage::init_module_for_test(&admin);

        let addresses = vector<address>[@0x100, @0x101, @0x102, @0x103, @0x104, @0x105, @0x106];
        let amounts = vector<u64>[
            100 * std::math64::pow(10, 6), 
            100 * std::math64::pow(10, 6), 
            100 * std::math64::pow(10, 6),
            100 * std::math64::pow(10, 6),
            100 * std::math64::pow(10, 6),
            100 * std::math64::pow(10, 6),
            100 * std::math64::pow(10, 6)
        ];
        let cliffs = vector[0, ONE_DAY_IN_SECONDS * 10, 0 , 0, 0, 0, 0]; // 2nd is 10 days
        let users = vector::empty<signer>();

        let total_amount = (100 + 100 + 100 + 100 + 100 + 100 + 100) * std::math64::pow(10, 6);

        let index = 0;
        while(index < vector::length(&mut addresses)){
            let user = account::create_account_for_test(*vector::borrow(&addresses, index ));
            vector::push_back(&mut users, user);
            index = index + 1;
        };


        let prev_apt_bablance = coin::balance<AptosCoin>(admin_address);
        let prev_usdc_balance = coin::balance<USDC>(admin_address);

        let from = timestamp::now_seconds();
        let to =  timestamp::now_seconds() + ONE_DAY_IN_SECONDS * 30; // 1 month;
        deposit<USDC>(
            &admin, 
            addresses, 
            amounts, 
            cliffs, 
            from,
            to,
        );
        let now_apt_bablance = coin::balance<AptosCoin>(admin_address);
        let now_usdc_balance = coin::balance<USDC>(admin_address);

        // ensure the fee in APT is deducted.
        assert!(prev_apt_bablance - now_apt_bablance == get_price(), 0);
        // ensure USDC is deducted.
        assert!(prev_usdc_balance - now_usdc_balance == total_amount, 1);

        assert!(vector::length(&get_vestings_by_owner(&admin)) == 1, 8);

        // lets changet the time to 2 days later.
        let now = timestamp::now_seconds() + ONE_DAY_IN_SECONDS * 2;
        timestamp::update_global_time_for_test_secs(now);

        let index = 0;
        let vesting_index = get_last_index();
        let claimed = vector::empty<u64>();

        while(index < vector::length(&mut addresses)){
            let user = vector::borrow(&users, index);

            coin::register<USDC>(user);

            let total_amount = *vector::borrow(&amounts, index);
            let cliff = *vector::borrow(&cliffs, index);
            let expected_amount = if(cliff == 0) total_amount * (now - from) / (to - from) else 0;

            if(cliff == 0){
                claim<USDC>(user, vesting_index); // cliff is set to 10 days, if would fail here. we just skip it for now.
                let actual_amount = coin::balance<USDC>(signer::address_of(user));

                std::debug::print(&expected_amount);
                assert!(expected_amount == actual_amount, 1);
                vector::push_back(&mut claimed, actual_amount);
            } else {
                std::debug::print(&expected_amount);
                vector::push_back(&mut claimed, 0);
            };

            index = index + 1;
        };    

        std::debug::print(&200000000000000);
        // now lets move forward to 10 days later, so in total 20 days. all users should be able to claim now.
        now = from + ONE_DAY_IN_SECONDS * 20;
        timestamp::update_global_time_for_test_secs(now);    
        index = 0;    
        while(index < vector::length(&mut addresses)){
            let user = vector::borrow(&users, index);

            let total_amount = *vector::borrow(&amounts, index);
            let user_claimed = vector::borrow_mut(&mut claimed, index);
            let cliff = *vector::borrow(&cliffs, index);
            let expected_amount = total_amount * (now - from - cliff) / (to - from - cliff) - *user_claimed;

            let prev_amount = coin::balance<USDC>(signer::address_of(user));
            claim<USDC>(user, vesting_index); 
            let now_amount = coin::balance<USDC>(signer::address_of(user));
            let actual_amount = now_amount - prev_amount;
            std::debug::print(&expected_amount);
            *user_claimed = *user_claimed + actual_amount;
            assert!(expected_amount == actual_amount, 2);

            index = index + 1;
        };          

        std::debug::print(&250000000000000);
        // now lets move forward to 10 days later, so in total 20 days. all users should be able to claim now.
        now = from + ONE_DAY_IN_SECONDS * 25;
        timestamp::update_global_time_for_test_secs(now);    
        index = 0;    
        while(index < vector::length(&mut addresses)){
            let user = vector::borrow(&users, index);

            let total_amount = *vector::borrow(&amounts, index);
            let user_claimed = vector::borrow_mut(&mut claimed, index);
            let cliff = *vector::borrow(&cliffs, index);
            let expected_amount = total_amount * (now - from - cliff) / (to - from - cliff) - *user_claimed;

            let prev_amount = coin::balance<USDC>(signer::address_of(user));
            claim<USDC>(user, vesting_index); 
            let now_amount = coin::balance<USDC>(signer::address_of(user));
            let actual_amount = now_amount - prev_amount;
            std::debug::print(&expected_amount);
            *user_claimed = *user_claimed + actual_amount;
            assert!(expected_amount == actual_amount, 3);

            index = index + 1;
        };        

        std::debug::print(&250000000000000);
        // now lets move forward to 10 days later, so in total 20 days. all users should be able to claim now.
        now = from + ONE_DAY_IN_SECONDS * 30;
        timestamp::update_global_time_for_test_secs(now);    
        index = 0;    
        while(index < vector::length(&mut addresses)){
            let user = vector::borrow(&users, index);

            let total_amount = *vector::borrow(&amounts, index);
            let user_claimed = vector::borrow_mut(&mut claimed, index);
            let cliff = *vector::borrow(&cliffs, index);
            let expected_amount = total_amount * (now - from - cliff) / (to - from - cliff) - *user_claimed;

            let prev_amount = coin::balance<USDC>(signer::address_of(user));
            claim<USDC>(user, vesting_index); 
            let now_amount = coin::balance<USDC>(signer::address_of(user));
            let actual_amount = now_amount - prev_amount;
            std::debug::print(&expected_amount);
            *user_claimed = *user_claimed + actual_amount;
            assert!(expected_amount == actual_amount, 4);

            index = index + 1;
        };                    
            
        // all should be gone, nothing to withdraw.
        prev_usdc_balance = coin::balance<USDC>(admin_address);
        withdraw<USDC>(&admin, vesting_index);
        now_usdc_balance = coin::balance<USDC>(admin_address);

        std::debug::print(&prev_usdc_balance);
        std::debug::print(&now_usdc_balance);
        assert!(prev_usdc_balance == now_usdc_balance, 3);
    }        
}