/*
Provides a singleton wrapper around PropertyMap to allow for easy and dynamic configurability of contract options.
Anyone can read, but only admins can write, as all write methods are gated via permissions checks
*/

module coin_factory::config {
    use aptos_token::property_map::{Self, PropertyMap, PropertyValue};
    use std::string::{ String};
    use std::signer;

    /// Raised if the signer is not authorized to perform an action
    const ENOT_AUTHORIZED: u64 = 1;
    /// Raised if there is an invalid value for a configuration
    const EINVALID_VALUE: u64 = 2;

    struct ConfigurationV1 has key, store {
        config: PropertyMap,
    }

    public fun register(owner: &signer) {
        move_to(owner, ConfigurationV1 {
            config: property_map::empty(),
        });
    }

    public fun remove_v1(account: &signer, config_name: &String): (String, PropertyValue) acquires ConfigurationV1 {
        let addr = signer::address_of(account);
        property_map::remove(&mut borrow_global_mut<ConfigurationV1>(addr).config, config_name)
    }

    public fun set_v1<T: copy>(account: &signer, config_name: String, value: &T) acquires ConfigurationV1 {
        let addr = signer::address_of(account);
        if(!exists<ConfigurationV1>(addr)) register(account);
        
        let map = &mut borrow_global_mut<ConfigurationV1>(addr).config;
        let value = property_map::create_property_value(value);
        if (property_map::contains_key(map, &config_name)) {
            property_map::update_property_value(map, &config_name, value);
        } else {
            property_map::add(map, config_name, value);
        };
    }

    public fun read_string_v1(addr: address, key: &String): String acquires ConfigurationV1 {
        property_map::read_string(&borrow_global<ConfigurationV1>(addr).config, key)
    }

    public fun read_u8_v1(addr: address, key: &String): u8 acquires ConfigurationV1 {
        property_map::read_u8(&borrow_global<ConfigurationV1>(addr).config, key)
    }

    public fun read_u64_v1(addr: address, key: &String): u64 acquires ConfigurationV1 {
        property_map::read_u64(&borrow_global<ConfigurationV1>(addr).config, key)
    }

    public fun read_address_v1(addr: address, key: &String): address acquires ConfigurationV1 {
        property_map::read_address(&borrow_global<ConfigurationV1>(addr).config, key)
    }

    public fun read_u128_v1(addr: address, key: &String): u128 acquires ConfigurationV1 {
        property_map::read_u128(&borrow_global<ConfigurationV1>(addr).config, key)
    }

    public fun read_bool_v1(addr: address, key: &String): bool acquires ConfigurationV1 {
        property_map::read_bool(&borrow_global<ConfigurationV1>(addr).config, key)
    }
}