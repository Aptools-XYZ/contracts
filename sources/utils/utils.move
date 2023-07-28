module coin_factory::utils {
    use std::string::{Self, String, utf8, bytes};
    use aptos_std::math64::{pow};
    use std::vector;
    use aptos_std::bcs;
    use aptos_std::type_info;
    use coin_factory::base64::encode;

    struct DecimalStringParams has drop {
        // significant figures of decimal
        sigfigs: u64,
        // length of decimal string
        buffer_length: u8,
        // ending index for significant figures (funtion works backwards when copying sigfigs)
        sigfig_index: u8,
        // index of decimal place (0 if no decimal)
        decimal_index: u8,
        // start index for trailing/leading 0"s for very small/large numbers
        zeros_start_index: u8,
        // end index for trailing/leading 0"s for very small/large numbers
        zeros_end_index: u8,
        // true if decimal number is less than one
        is_less_than_one: bool
    }

    public fun type_to_string<X>(): String {
        let type = & type_info::type_of<X>();
        let coin_address = address_to_string(&type_info::account_address(type));
        let coin_module = type_info::module_name(type);
        let struct_name = type_info::struct_name(type);

        let coin = string::utf8(b"");
        string::append(&mut coin, coin_address);
        string::append_utf8(&mut coin, b"::");
        string::append_utf8(&mut coin, coin_module);
        string::append_utf8(&mut coin, b"::");
        string::append_utf8(&mut coin, struct_name);    

        coin
    }    

    public fun base64_encode(input: &String): String {
        utf8(encode(bytes(input)))
    }

    const EINVALID_INPUT: u64 = 0;
  
    public fun address_to_string(input: &address): String {
        let bytes = bcs::to_bytes<address>(input);
        let i = 0;
        let result = vector[48, 120];
        while (i < vector::length<u8>(&bytes)) {
            vector::append(&mut result, u8_to_hex_string_u8(*vector::borrow<u8>(&bytes, i)));
            i = i + 1;
        };

        remove_leading_zeros(&mut result);

        utf8(result)
    }

    fun u8_to_hex_string_u8(input: u8): vector<u8> {
        let result = vector::empty<u8>();
        vector::push_back(&mut result, u4_to_hex_string_u8(input / 16));
        vector::push_back(&mut result, u4_to_hex_string_u8(input % 16));
        //string::utf8(result)
        result
    }

    fun u4_to_hex_string_u8(input: u8): u8 {
        assert!(input<=15, EINVALID_INPUT);
        if (input<=9) (48 + input) // 0 - 9 => ASCII 48 to 57
        else (55 + 32 + input) //10 - 15 => ASCII 65 to 70 // 32 is to small cases
    }    

    public fun u64_to_string(num: u64): String{
        if (num == 0) 
            return utf8(b"0");

        let v1 = vector::empty();

        while (num/10 > 0){
            let rem = num%10;
            vector::push_back(&mut v1, ((rem+48 as u8)));
            num = num/10;
        };
        vector::push_back(&mut v1, (num+48 as u8));
        vector::reverse(&mut v1);
        utf8(v1)
    }

    /// This turns a u128 into its UTF-8 string equivalent.
    public fun u128_to_string(value: u128): String {
        if (value == 0) {
            return utf8(b"0")
        };
        let buffer = vector::empty<u8>();
        while (value != 0) {
            vector::push_back(&mut buffer, ((48 + value % 10) as u8));
            value = value / 10;
        };
        vector::reverse(&mut buffer);
        utf8(buffer)
    }    

    public fun fixed_point_to_decimal_string( _value: u64, _decimals: u8): String {
        if (_value == 0)
            return utf8(b"0");

        let powed = (pow(10u64, (_decimals as u64)));
        let price_below_1 = _value < powed;

        // get digit count
        let _temp = _value;
        let _digits: u8 = 0;
        while (_temp != 0) {
            _digits = _digits + 1;
            _temp = _temp / 10;
        };
        // don"t count extra digit kept for rounding
        _digits = _digits - 1;

        // address rounding
        let (_sigfigs, _extra_digit) = sigfigs_rounded(_value, _digits);
        if (_extra_digit) {
            _digits = _digits + 1;
        };


        let (_buffer_length, zeros_start_index, zeros_end_index, _sigfig_index, decimal_index, sigfigs, is_less_than_one) = (0, 0, 0, 0, 0, _sigfigs, price_below_1);
        if (price_below_1) {
            // 7 bytes ( "0." and 5 sigfigs) + leading 0"s bytes
            _buffer_length = if (_digits >= 5) _decimals - _digits + 6 else _decimals + 2;
            zeros_start_index = 2;
            zeros_end_index = _decimals - _digits + 1;
            _sigfig_index = _buffer_length - 1;
        } else if (_digits >= _decimals + 4) {
            // no decimal in price string
            _buffer_length = _digits - _decimals + 1;
            zeros_start_index = 5;
            zeros_end_index = _buffer_length - 1;
            _sigfig_index = 4;
        } else {
            // 5 sigfigs surround decimal
            _buffer_length = 6;
            _sigfig_index = 5;
            decimal_index = _digits - _decimals + 1;
        };

        let params = DecimalStringParams {
            buffer_length: _buffer_length,
            zeros_start_index,
            zeros_end_index,
            sigfig_index: _sigfig_index,
            decimal_index,
            sigfigs,
            is_less_than_one
        };

        generate_decimal_string(&mut params)
    }

    public fun generate_vector<T: copy + drop>(length: u8, defaultValue: T): vector<T> {
        let v = vector::empty<T>();
        let i = 0;
        while (i < length) {
            vector::push_back(&mut v, copy defaultValue);
            i = i + 1;
        };

        v
    }

    public fun set_value<T: drop>(v: &mut vector<T>, i: u64, value: T) {
        assert!(vector::length<T>(v) > i, 0);
        *vector::borrow_mut<T>(v, i) = value;
    }

    fun generate_decimal_string(_params: &mut DecimalStringParams): String {
        let _buffer = generate_vector<u8>(_params.buffer_length, 0);
        let (dot, zero) = (46, 48);

        if (_params.is_less_than_one) {
            set_value(&mut _buffer, 0, zero);
            set_value(&mut _buffer, 1, dot); // 46 is for '.'
        };

        let _zerosCursor = _params.zeros_start_index;
        // add leading/trailing 0"s
        while (_zerosCursor < _params.zeros_end_index + 1 ) {
            set_value(&mut _buffer, (_zerosCursor as u64), zero);
            _zerosCursor = _zerosCursor + 1;
        };
        // add sigfigs
        while (_params.sigfigs > 0) {
            if (_params.decimal_index > 0 && _params.sigfig_index == _params.decimal_index) {
                set_value(&mut _buffer, (_params.sigfig_index as u64), dot);
                _params.sigfig_index = _params.sigfig_index - 1;
            };
            let _charIndex = (48 + (_params.sigfigs % 10));
            set_value(&mut _buffer, (_params.sigfig_index as u64), (_charIndex as u8));
            _params.sigfigs = _params.sigfigs / 10;
            if (_params.sigfigs > 0) {
                _params.sigfig_index = _params.sigfig_index - 1;
            };
        };

        remove_trailling_zeros(&mut _buffer);
        utf8(_buffer)
    }

   fun remove_leading_zeros(v: &mut vector<u8>) {
        let (zero) = (48u8);
        let index = 0;
        vector::reverse(v);
        vector::pop_back(v); // remove 0
        let x = vector::pop_back(v); // remove x

        let length = vector::length(v); // ignore the 0 and x
        while (length > index) {
            length = length - 1;
            let value_at_index = *vector::borrow<u8>(v, length);
            if (value_at_index == zero)
                vector::pop_back(v)
            else
                break;
        };

        vector::push_back(v, x);
        vector::push_back(v, zero);
        vector::reverse(v)
    }    

    fun remove_trailling_zeros(v: &mut vector<u8>) {
        let (dot, zero) = (46u8, 48u8);
        let (found, index) = vector::index_of(v, &dot);
        if (found) {
            let length = vector::length(v);
            while (length > index) {
                length = length - 1;
                let value_at_index = *vector::borrow<u8>(v, length);
                if (value_at_index == zero)
                    vector::pop_back(v)
                else
                    break;
            };
        };

        let length = vector::length(v);
        let last = *vector::borrow<u8>(v, length - 1);
        if (last == dot) { vector::pop_back(v); }
    }

    fun sigfigs_rounded(_value: u64, _digits: u8): (u64, bool) {
        let _extra_digit: bool = false;
        if (_digits > 5)
            _value = _value / pow(10u64, ((_digits - 5) as u64));

        let _roundUp = _value % 10 > 4;
        _value = _value / 10;
        if (_roundUp)
            _value = _value + 1;

        // 99999 -> 100000 gives an extra sigfig
        if (_value == 100000) {
            _value = _value / 10;
            _extra_digit = true;
        };
        return (_value, _extra_digit)
    }

    #[test]
    fun test_address_to_string() {
        let test_addr = @0xdf67f176cdf8adfa616620d5499a20739fc437338af022670cf4d511edbb9365;
        let addr_string_u81 = utf8(b"0xdf67f176cdf8adfa616620d5499a20739fc437338af022670cf4d511edbb9365");
        let addr_string_u82 = address_to_string(&test_addr);
        assert!(addr_string_u81 == addr_string_u82, 0);

        let test_addr = @0x1;
        let addr_string_u81 = utf8(b"0x1");
        let addr_string_u82 = address_to_string(&test_addr);

        std::debug::print(&addr_string_u81);
        std::debug::print(&addr_string_u82);
        assert!(addr_string_u81 == addr_string_u82, 0);        
    }

    #[test]
    fun test_zero() {
        let amount = 0u64;
        let decimals = 8u8;

        let str = coin_factory::utils::fixed_point_to_decimal_string(amount, decimals);
        assert!(str == utf8(b"0"), 0);
    }

    #[test]
    fun test_with_decimals() {
        let amount = 100010u64;
        let decimals = 8u8;

        let str = coin_factory::utils::fixed_point_to_decimal_string(amount, decimals);
        assert!(str == utf8(b"0.0010001"), 1);
    }

    #[test]
    fun test_with_above_1() {
        let amount = 100000000u64;
        let decimals = 8u8;

        let str = coin_factory::utils::fixed_point_to_decimal_string(amount, decimals);
        assert!(str == utf8(b"1"), 2);

        amount = 120000010u64;
        str = coin_factory::utils::fixed_point_to_decimal_string(amount, decimals);
        // std::debug::print(&str);
        assert!(str == utf8(b"1.2"), 3);

        amount = 120100000u64;
        str = coin_factory::utils::fixed_point_to_decimal_string(amount, decimals);
        // print(&str);
        assert!(str == utf8(b"1.201"), 4);
    }
}