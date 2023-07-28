/// Steps:
/// 1. deposite_fee_for to deposit fee first for an account to create a key of a coin.
/// 2. call API to create a coin and then all the created coin will be saved into this factory.
/// 3. call withdraw to take all the tokens to the creator.
module coin_factory::factory_v2 {
    use std::signer;
    use std::math64;
    use std::vector;
    use std::timestamp;
    use std::string::{utf8, String};
    use std::account::{Self, SignerCapability};

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::{AptosCoin};

    use aptos_std::table_with_length::{Self as table, TableWithLength as Table};

    use coin_factory::utils;
    use coin_factory::dao_storage;
    use coin_factory::config;

    struct AccountCapability has key { signer_cap: SignerCapability } 

    struct OwnerBalances has key {
        balances: Table<address, u64>,
    }

    struct Store<phantom X> has key {
        reserve: Coin<X>,
        owner: address,
    }

    struct IssueInfo has key, store, drop {
        coin_address: String,
        owner: address,
        created_at: u64,
        total_supply: u64,
    }

    struct InfoStore has key {
        coin_list: vector<IssueInfo>,
    }

    const E_NO_PERMISSION: u64 = 0;
    const E_NO_BALANCE: u64 = 1;
    const E_INVALID_PARAMETER: u64 = 2;

    const CONFIG_PRICE: vector<u8> = b"PRICE";

    fun init_module(coin_factory: &signer){
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_factory_seed_v2");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        move_to(&resource_signer, OwnerBalances{
            balances: table::new<address, u64>()
        });

        dao_storage::register<AptosCoin>(); 
        config::register(&resource_signer);

        config::set_v1(&resource_signer, utf8(CONFIG_PRICE), &(5 * math64::pow(10, 8)));

        move_to(&resource_signer, InfoStore {
            coin_list: vector::empty<IssueInfo>(),
        });           
    }

    fun get_price():u64 acquires AccountCapability{
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);        
        config::read_u64_v1(resource_address, &utf8(CONFIG_PRICE))
    }

    public fun get_base_price():u64 acquires AccountCapability{
        get_price()
    }

    /// this only visible to the coin maker account.
    public fun deposit_for<X>(account: &signer, token_owner_addr: address, coins: Coin<X>) 
        acquires AccountCapability, OwnerBalances, InfoStore
    {
        assert!(signer::address_of(account) == @coin_maker, E_NO_PERMISSION);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        // consume balance after tokens are created.
        let amount = get_price();
        let owner_balances = &mut borrow_global_mut<OwnerBalances>(resource_address).balances;
        let current_balannce = *table::borrow_mut_with_default(owner_balances, token_owner_addr, 0);
        assert!(current_balannce>= amount, E_NO_BALANCE);
        table::upsert(owner_balances, token_owner_addr, current_balannce - amount);          

        let info_store = &mut borrow_global_mut<InfoStore>(resource_address).coin_list;
        vector::push_back(info_store, IssueInfo {
            owner: token_owner_addr,
            total_supply: coin::value(&coins),
            created_at: timestamp::now_seconds(),
            coin_address: utils::type_to_string<X>(),
        });

        move_to(&resource_account, Store<X> {
            reserve: coins,
            owner: token_owner_addr
        });
    }    

    public entry fun set_price(account: &signer, new_fee_without_decimals: u8) acquires AccountCapability{
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);

        assert!(signer::address_of(account) == dao_storage::get_fee_collector(), E_NO_PERMISSION);
        config::set_v1(&resource_account, utf8(CONFIG_PRICE), &((new_fee_without_decimals as u64) * math64::pow(10, 8)));
    }

    public entry fun deposit_fee_for(account: &signer) acquires AccountCapability, OwnerBalances {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let amount = get_price();

        // pay APT to collector to be able to withdraw
        let apt_coins = coin::withdraw<AptosCoin>(account, amount);
        dao_storage::deposit<AptosCoin>(apt_coins);  

        // add to owner balance.
        let owner_balances = &mut borrow_global_mut<OwnerBalances>(resource_address).balances;
        let current_balannce = *table::borrow_mut_with_default(owner_balances, signer::address_of(account), 0);
        table::upsert(owner_balances, signer::address_of(account), current_balannce + amount);                  
    }

    public entry fun withdraw<X>(account: &signer) acquires Store, AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);     

        // send back the coin created.
        let store = borrow_global_mut<Store<X>>(resource_address);
        // check ownership
        assert!(store.owner == signer::address_of(account), E_NO_PERMISSION);          

        let balance = coin::value<X>(&store.reserve);
        let coins_to_withdraw = coin::extract(&mut store.reserve, balance);
        if(!coin::is_account_registered<X>(signer::address_of(account)))
            coin::register<X>(account);
        coin::deposit<X>(signer::address_of(account), coins_to_withdraw);
    }
}