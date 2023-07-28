module coin_factory::dao_storage {
    use std::signer;
    use std::vector;
    use std::string::{String, utf8};

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event;

    use coin_factory::utils;
    use coin_factory::config;

    // Error codes.

    /// When invalid DAO admin account
    const E_NO_PERMISSION: u64 = 402;
    const E_INVALID_PARAMETER: u64 = 403;
    const E_NO_BALANCE: u64 = 404;
    const E_NO_CHANGE: u64 = 405;

    // Public functions.
    struct AccountCapability has key { signer_cap: SignerCapability } 

    /// Storage for keeping coins
    struct Reserve<phantom X> has key {
        reserve: Coin<X>,
    }

    struct CoinList has key {
        coins: vector<String>,
    }

    const CONFIG_FEE_COLLECTOR: vector<u8> = b"FEE_COLLECTOR";

    fun init_module(coin_factory: &signer) {
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_storage_seed");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        move_to(&resource_signer, CoinList {
            coins: vector::empty<String>(),
        });

        config::set_v1(&resource_signer, utf8(CONFIG_FEE_COLLECTOR), &@fee_collector);
    }

    public fun register<X>()
        acquires AccountCapability, CoinList
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        if(!exists<Reserve<X>>(resource_address)) 
            move_to(&resource_account, Reserve<X> {
                reserve: coin::zero<X>(),
            });

        if(!exists<EventsStore<X>>(resource_address)){
            let events_store = EventsStore<X> {
                coin_registered_handle: account::new_event_handle(&resource_account),
                coin_deposited_handle: account::new_event_handle(&resource_account),
                coin_withdrawn_handle: account::new_event_handle(&resource_account)
            };
            event::emit_event(
                &mut events_store.coin_registered_handle,
                StorageCreatedEvent<X> {}
            );
            move_to(&resource_account, events_store);  
        };

        let coin_list = &mut borrow_global_mut<CoinList>(resource_address).coins;
        let coin_str = utils::type_to_string<X>();
        if(!vector::contains(coin_list, &coin_str))
            vector::push_back(coin_list, coin_str);
    }

    public fun deposit<X>(coins: Coin<X>) acquires Reserve, CoinList, EventsStore, AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);
        let amount = coin::value(&coins);

        register<X>();

        let reserve = &mut borrow_global_mut<Reserve<X>>(resource_address).reserve;
        coin::merge(reserve, coins);

        let events_store = borrow_global_mut<EventsStore<X>>(resource_address);
        event::emit_event(
            &mut events_store.coin_deposited_handle,
            CoinDepositedEvent<X> { amount }
        );        
    }

    public fun get_fee_collector(): address acquires AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        config::read_address_v1(resource_address, &utf8(CONFIG_FEE_COLLECTOR))
    }

    public entry fun withdraw<X>(account: &signer, amount: u64)
        acquires AccountCapability,Reserve, EventsStore 
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let fee_collector =  get_fee_collector();

        assert!(signer::address_of(account) == fee_collector, E_NO_PERMISSION);
        assert!(amount>0, E_INVALID_PARAMETER);

        let reserve = &mut borrow_global_mut<Reserve<X>>(resource_address).reserve;
        let balance = coin::value(reserve);
        assert!(balance >= amount, E_NO_BALANCE);

        let coins = coin::extract(reserve, amount);
        
        if(!coin::is_account_registered<X>(signer::address_of(account)))
            coin::register<X>(account);

        coin::deposit(signer::address_of(account), coins);

        let events_store = borrow_global_mut<EventsStore<X>>(resource_address);
        event::emit_event(
            &mut events_store.coin_withdrawn_handle,
            CoinWithdrawnEvent<X> { amount }
        );         
    }

    public entry fun set_fee_collector(account: &signer, new_fee_collector: address) 
        acquires AccountCapability
    {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);

        assert!(signer::address_of(account) == get_fee_collector(), E_NO_PERMISSION);
        assert!(new_fee_collector != signer::address_of(account), E_NO_CHANGE);

        config::set_v1(&resource_account, utf8(CONFIG_FEE_COLLECTOR), &new_fee_collector);
    }    

    // Events

    struct EventsStore<phantom X> has key {
        coin_registered_handle: event::EventHandle<StorageCreatedEvent<X>>,
        coin_deposited_handle: event::EventHandle<CoinDepositedEvent<X>>,
        coin_withdrawn_handle: event::EventHandle<CoinWithdrawnEvent<X>>,
    }

    struct StorageCreatedEvent<phantom X> has store, drop {}
    struct CoinDepositedEvent<phantom X> has store, drop {  amount: u64, }
    struct CoinWithdrawnEvent<phantom X> has store, drop { amount: u64, }

    #[test_only]
    public fun init_module_for_test(owner: &signer) {
        init_module(owner);
    }    
}
