/// Steps:
/// 1. deposite_fee_for to deposit fee first for an account to create a key of a coin.
/// 2. call API to create a coin and then all the created coin will be saved into this factory.
/// 3. call withdraw to take all the tokens to the creator.
module coin_factory::factory {
    use std::signer;
    use std::math64;
    use std::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::{AptosCoin};

    use aptos_std::table_with_length::{Self as table, TableWithLength as Table};

    struct AccountCapability has key { signer_cap: SignerCapability } 

    struct Config has key {
        price: u64,
        fee_collector: address
    }

    struct OwnerBalances has key {
        balances: Table<address, u64>,
    }

    struct Store<phantom X> has key {
        reserve: Coin<X>,
        owner: address,
    }

    struct FeeStore has key{
        reserve: Coin<AptosCoin>
    }

    const E_NO_PERMISSION: u64 = 0;
    const E_NO_BALANCE: u64 = 1;
    const E_INVALID_PARAMETER: u64 = 2;

    fun init_module(coin_factory: &signer){
        let (resource_signer, resource_signer_cap) = account::create_resource_account(coin_factory, b"coin_factory_seed");        
        move_to(coin_factory, AccountCapability { signer_cap:resource_signer_cap });

        move_to(&resource_signer, OwnerBalances{
            balances: table::new<address, u64>()
        });

        move_to(&resource_signer, Config {
            price: 5 * math64::pow(10, 8),
            fee_collector: @fee_collector
        });

        move_to(&resource_signer, FeeStore {
            reserve: coin::zero<AptosCoin>()
        });   
    }

    /// this only visible to the coin maker account.
    public fun deposit_for<X>(account: &signer, token_owner_addr: address, coins: Coin<X>) acquires AccountCapability, OwnerBalances, Config{
        assert!(signer::address_of(account) == @coin_maker, E_NO_PERMISSION);

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        // consume balance after tokens are created.
        let config = borrow_global<Config>(resource_address);
        let amount = config.price;
        let owner_balances = &mut borrow_global_mut<OwnerBalances>(resource_address).balances;
        let current_balannce = *table::borrow_mut_with_default(owner_balances, token_owner_addr, 0);
        assert!(current_balannce>= amount, E_NO_BALANCE);
        table::upsert(owner_balances, token_owner_addr, current_balannce - amount);          

        move_to(&resource_account, Store<X> {
            reserve: coins,
            owner: token_owner_addr
        });
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
        config.price = (new_fee_without_decimals as u64) * math64::pow(10, 8);
    }  

    public fun get_price(): u64 acquires Config, AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        borrow_global<Config>(resource_address).price
    }

    public fun has_balance_for(account: &signer): bool acquires AccountCapability, OwnerBalances, Config {
        let price = get_price();

        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let owner_balances = &borrow_global<OwnerBalances>(resource_address).balances;
        let current_balannce = *table::borrow(owner_balances, signer::address_of(account));

        current_balannce >= price
    }

    public entry fun collect_fee(account: &signer, amount: u64) acquires Config, FeeStore, AccountCapability {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let config = borrow_global<Config>(resource_address);
        let fee_collector = config.fee_collector;

        assert!(signer::address_of(account) == fee_collector, E_NO_PERMISSION);
        assert!(amount>0, E_INVALID_PARAMETER);
        
        let fee_store = borrow_global_mut<FeeStore>(resource_address);
        let balance = coin::value(&fee_store.reserve);
        assert!(balance >= amount, E_NO_BALANCE);
        let apt_withdraw = coin::extract(&mut fee_store.reserve, amount);
        coin::deposit(signer::address_of(account), apt_withdraw);
    }

    public entry fun deposit_fee_for(account: &signer) acquires Config, AccountCapability, OwnerBalances, FeeStore {
        let cap = borrow_global<AccountCapability>(@coin_factory);
        let resource_account = account::create_signer_with_capability(&cap.signer_cap);
        let resource_address = signer::address_of(&resource_account);

        let amount = get_price();
        let fee_store = borrow_global_mut<FeeStore>(resource_address);

        // pay APT to collector to be able to withdraw
        let apt_coins = coin::withdraw<AptosCoin>(account, amount);
        coin::merge<AptosCoin>(&mut fee_store.reserve, apt_coins);    

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