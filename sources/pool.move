module pool_addr::Multi_Token_Pool {
    use std::signer;
    use std::vector;
    use std::debug::print;
    use std::aptos_account;
    use std::account;
    use std::option;
    use std::string::{Self, String};
    use std::simple_map::{Self, SimpleMap};
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata, FungibleAsset};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use pool_addr::Pool_Math;
    use lst_addr::Liquid_Staking_Token;

    const ERR_LIMIT_IN:u64 = 0;
    const ERR_TEST: u64 = 101;
    const ERR_BAD_LIMIT_PRICE:u64 = 1;
    const ERR_LIMIT_OUT:u64 = 2;
    const ERR_MATH_APPROX:u64 = 3;
    const ERR_LIMIT_PRICE:u64 = 4;

    const INIT_POOL_SUPPLY: u64 = 100 * 1000000;
    const BONE: u64 = 1000000;
    const MIN_FEE: u64 = 1000;

    struct PoolInfo has key {
        total_weight: u64,
        swap_fee: u64,
        is_finalized: bool,
    }

    struct Record has key, store, drop {
        bound: bool,
        index: u64, 
        denorm: u64,
        balance: u64,
        name: String,
        symbol: String,
    }

    struct TokenList has key, store {
        token_list: vector<address>,
    }

    struct TokenRecord has key, store {
        records: SimpleMap<address, Record>,
    }

    fun init_module(sender: &signer) {
        let token_list = TokenList {
            token_list: vector::empty(),
        };
        move_to(sender, token_list);

        let token_record = TokenRecord {
            records: simple_map::create(),
        };
        move_to(sender, token_record);

        let pool_info = PoolInfo {
            total_weight: 0,
            swap_fee: MIN_FEE,
            is_finalized: false,
        };
        move_to(sender, pool_info);

        let constructor_ref = object::create_named_object(sender, b"FA Generator");
        let fa_generator_extend_ref = object::generate_extend_ref(&constructor_ref);

        let name = string::utf8(b"LP Token");
        let symbol = string::utf8(b"LPT");
        let decimals = 6;
        let icon_uri = string::utf8(b"http://example.com/favicon.ico");
        let project_uri = string::utf8(b"http://example.com");
        Liquid_Staking_Token::create_fa(@lst_addr, name, symbol, decimals, icon_uri, project_uri);
    }

    // =============================== Entry Function =====================================

    // mint and push LP Token to owner
    public entry fun finalize(sender: &signer) acquires PoolInfo {
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        pool_info.is_finalized = true;
        mint_and_push_pool_share(sender, @pool_addr, INIT_POOL_SUPPLY);
    }

    public entry fun set_swap_fee(sender: &signer, swap_fee: u64) acquires PoolInfo {
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        pool_info.swap_fee = swap_fee;
    }

    // @todo: require token lengths not max bound
    public entry fun bind(sender: &signer, balance: u64, denorm: u64, name: String, symbol: String) acquires TokenRecord, TokenList, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let record = Record {
            bound: true,
            index: vector::length(&token_list.token_list),
            denorm: 0, // denorm and balance will be validated
            balance: 0, //  and set by rebind
            name: name,
            symbol: symbol,
        };

        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        simple_map::add(&mut token_record.records, token_address, record);
        vector::push_back(&mut token_list.token_list, token_address);
        rebind(sender, balance, denorm, name, symbol);
    }

    public entry fun rebind(sender: &signer, balance: u64, denorm: u64, name: String, symbol: String) acquires TokenRecord, TokenList, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);

        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        
        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_address);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);

        let old_weight = record.denorm;
        if(old_weight < denorm) {
            pool_info.total_weight = pool_info.total_weight + denorm - old_weight;
        } else {
            pool_info.total_weight = pool_info.total_weight + old_weight - denorm;
        };
        record.denorm = denorm;

        // adjust the balance record and actual token balance
        let old_balance = record.balance;
        record.balance = balance;
        if(balance > old_balance) {
            pull_underlying(sender, balance - old_balance, name, symbol);
        } else {
            pull_underlying(sender, old_balance - balance, name, symbol);
        }

    }

    public entry fun unbind(sender: &signer, name: String, symbol: String) acquires TokenRecord, TokenList, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);

        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_address);
        let token_balance = record.balance;
        pool_info.total_weight = pool_info.total_weight - record.denorm;

        // swap the token-to-unbind with the last token
        // then delete the last token
        let index = record.index;
        let last = vector::length(&token_list.token_list) - 1;
        let address_last = {
            let addr = *vector::borrow(&token_list.token_list, last);
            addr
        };
        // print(&token_address);
        // print(&address_index);
        // let i = 0;
        // while (i <= last) {
        //     let addr = *vector::borrow(&token_list.token_list, (i as u64));
        //     print(&addr);
        //     i = i + 1;
        // };
        vector::swap(&mut token_list.token_list, index, last);
        record.bound = false;
        record.balance = 0;
        record.index = 0;
        record.denorm = 0;
        record.name = string::utf8(b"");
        record.symbol = string::utf8(b"");
        
        simple_map::remove<address, Record>(&mut token_record.records, &token_address);
        if(index != last) {
            let record_last = simple_map::borrow_mut<address, Record>(&mut token_record.records, &address_last);
            record_last.index = index;
        };
        vector::pop_back(&mut token_list.token_list);
        push_underlying(sender, token_balance, name, symbol);
    }

    public entry fun swap (
        sender: &signer,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u64,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u64,
    ){
        pull_underlying(sender, token_amount_in, token_in_name, token_in_symbol);
        push_underlying(sender, token_amount_out, token_out_name, token_out_symbol);
    }

    public entry fun join_swap (
        sender: &signer,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u64,
        pool_amount_out: u64,
    ) {
        let sender_addr = signer::address_of(sender);
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
        pull_underlying(sender, token_amount_in, token_in_name, token_in_symbol,);
    }

    public entry fun exit_swap(
        sender: &signer,
        token_out_name: String,
        token_out_symbol: String,
        pool_amount_in: u64,
        token_amount_out: u64,
    ) {
        let sender_addr = signer::address_of(sender);
        pull_pool_share(sender, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool_amount_in);
        push_underlying(sender, token_amount_out, token_out_name, token_out_symbol);
    }

    public entry fun join_pool(sender: &signer, pool_amount_out: u64, max_amounts_in: vector<u64>) acquires TokenList, TokenRecord {
        let sender_addr = signer::address_of(sender);
        let pool_total = get_total_supply_lpt();
        let ratio = Pool_Math::div(pool_amount_out, pool_total);
        // print(&pool_amount_out);
        // print(&pool_total);
        // print(&ratio);
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_list_length = vector::length(&token_list.token_list);
        let i = 0;
        while (i < token_list_length) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, token_address);
            let max_amount_in = vector::borrow(&max_amounts_in, (i as u64));
            let name = record.name;
            let symbol = record.symbol;
            // Amount In to deposit
            let token_amount_in = Pool_Math::mul(ratio, record.balance);
            assert!(token_amount_in <= *max_amount_in, ERR_LIMIT_IN);

            record.balance = record.balance + token_amount_in;
            pull_underlying(sender, token_amount_in, name, symbol);
            i = i + 1;
        };
        
        // todo: mint and deposit LP Token to sender
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
    }

    public entry fun exit_pool(sender: &signer, pool_amount_in: u64, min_amounts_out: vector<u64>) acquires TokenList, TokenRecord {
        let sender_addr = signer::address_of(sender);
        let pool_total = get_total_supply_lpt();
        let ratio = Pool_Math::div(pool_amount_in, pool_total);
        // print(&pool_amount_in);
        // print(&pool_total);
        // print(&ratio);
        pull_pool_share(sender, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool_amount_in);
        
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_list_length = vector::length(&token_list.token_list);
        let i = 0;
        while (i < token_list_length) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, token_address);
            let min_amount_out = vector::borrow(&min_amounts_out, (i as u64));
            let name = record.name;
            let symbol = record.symbol;
            let token_amount_out = Pool_Math::mul(ratio, record.balance);
            // print(&ratio);
            // print(&record.balance);
            // print(&token_amount_out);
            record.balance = record.balance - token_amount_out;
            push_underlying(sender, token_amount_out, name, symbol);
            i = i + 1;
        }
    }

    // ========================================= View Function ==========================================

    #[view]
    public fun get_total_denormalized_weight(): u64 acquires PoolInfo {
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        pool_info.total_weight
    }

    #[view]
    public fun get_token_number(): u64 acquires TokenList {
        let token_list = borrow_global<TokenList>(@pool_addr);
        vector::length(&token_list.token_list)
    }

    #[view]
    public fun get_swap_exact_amount_in(
        sender_addr: address,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u64,
        token_out_name: String,
        token_out_symbol: String,
        min_amount_out: u64,
        max_price: u64,
    ): (u64, u64) acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);

        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);    
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        
        let spot_price_before = Pool_Math::calc_spot_price (
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_before <= max_price, ERR_BAD_LIMIT_PRICE);

        let token_amount_out = Pool_Math::calc_out_given_in(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            token_amount_in,
            pool_info.swap_fee,
        );
        assert!(token_amount_out >= min_amount_out, ERR_LIMIT_OUT);
        {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            record_token_in.balance = record_token_in.balance - token_amount_in;
        };
       
        {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            record_token_out.balance = record_token_out.balance + token_amount_out;
        };

        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price_after = Pool_Math::calc_spot_price(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_after >= spot_price_after, ERR_MATH_APPROX);
        assert!(spot_price_after <= max_price, ERR_LIMIT_PRICE);

        (token_amount_out, spot_price_after)
    }

    #[view]
    public fun get_swap_exact_amount_out (
        sender_addr: address,
        token_in_name: String,
        token_in_symbol: String,
        max_amount_in: u64,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u64,
        max_price: u64,
    ): (u64, u64) acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);    
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price_before = Pool_Math::calc_spot_price (
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_before <= max_price, ERR_BAD_LIMIT_PRICE);
        let token_amount_in = Pool_Math::calc_in_given_out(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            token_amount_out,
            pool_info.swap_fee,
        );
        assert!(token_amount_in <= max_amount_in, ERR_LIMIT_IN);
        {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            record_token_in.balance = record_token_in.balance - token_amount_in;
        };
        {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            record_token_out.balance = record_token_out.balance + token_amount_out;
        };
        let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price_after = Pool_Math::calc_spot_price(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_after >= spot_price_after, ERR_MATH_APPROX);
        assert!(spot_price_after <= max_price, ERR_LIMIT_PRICE);

        (token_amount_in, spot_price_after)
    }

    #[view]
    public fun get_join_swap_extern_amount_in (
        sender_addr: address,
        token_in_name: String,
        token_in_symbol: String, 
        token_amount_in: u64,
        min_pool_amount_out: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
        let total_supply_lpt = get_total_supply_lpt();
        let pool_amount_out = Pool_Math::calc_pool_out_given_single_in(
            record_token_in.balance,
            record_token_in.denorm,
            total_supply_lpt,
            pool_info.total_weight,
            token_amount_in,
            pool_info.swap_fee,
        );
        // print(&pool_amount_out);
        assert!(pool_amount_out >= min_pool_amount_out, ERR_LIMIT_OUT);
        record_token_in.balance = record_token_in.balance + token_amount_in;
        pool_amount_out
    }

    #[view]
    public fun get_join_swap_pool_amount_out (
        sender_addr: address,
        token_in_name: String,
        token_in_symbol: String,
        pool_amount_out: u64,
        max_amount_in: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
        let total_supply_lpt = get_total_supply_lpt();
        let token_amount_in = Pool_Math::calc_single_in_given_pool_out (
            record_token_in.balance,
            record_token_in.denorm,
            total_supply_lpt,
            pool_info.total_weight,
            pool_amount_out,
            pool_info.swap_fee,
        );
        assert!(token_amount_in <= max_amount_in, ERR_LIMIT_IN);
        record_token_in.balance = record_token_in.balance + token_amount_in;
        token_amount_in
    }

    #[view] 
    public fun get_exit_swap_pool_amount_in (
        sender_addr: address,
        token_in_name: String,
        token_in_symbol: String,
        pool_amount_in: u64,
        min_amount_out: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
        let total_supply_lpt = get_total_supply_lpt();
        let token_amount_out = Pool_Math::calc_single_out_given_pool_in (
            record_token_out.balance,
            record_token_out.denorm,
            total_supply_lpt,
            pool_info.total_weight,
            pool_amount_in,
            pool_info.swap_fee
        );
        assert!(token_amount_out >= min_amount_out, ERR_LIMIT_OUT);
        record_token_out.balance = record_token_out.balance - token_amount_out;
        token_amount_out
    }

    #[view]
    public fun get_exit_swap_extern_amount_out(
        sender_addr: address,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u64,
        max_pool_amount_in: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);
        let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
        let total_supply_lpt = get_total_supply_lpt();
        let pool_amount_in = Pool_Math::calc_pool_in_given_single_out (
            record_token_out.balance,
            record_token_out.denorm,
            total_supply_lpt,
            pool_info.total_weight,
            token_amount_out,
            pool_info.swap_fee,
        );
        assert!(pool_amount_in <= max_pool_amount_in, ERR_LIMIT_IN);
        record_token_out.balance = record_token_out.balance -  token_amount_out;
        pool_amount_in
    }

    #[view] 
    public fun get_total_supply_lpt(): u64 {
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::get_total_supply(lpt_name, lpt_symbol)
    }

    #[view]
    public fun get_total_supply(name: String, symbol: String): u64{
        Liquid_Staking_Token::get_total_supply(name, symbol)
    }

    #[view]
    public fun get_balance(sender_addr: address, name: String, symbol: String): u64 {
        Liquid_Staking_Token::get_balance(sender_addr, name, symbol)
    }

    #[view]
    public fun get_num_tokens(): u64 acquires TokenList {
        let token_list = borrow_global<TokenList>(@pool_addr);
        vector::length(&token_list.token_list)
    }

    #[view]
    public fun get_token_name_list(): vector<String> acquires TokenList, TokenRecord {
        let token_name_list= vector::empty<String>();
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let num_tokens = vector::length(&token_list.token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow(&token_record.records, token_address);
            let token_name = record.name;
            vector::push_back(&mut token_name_list, token_name);
            i = i + 1;
        };
        token_name_list
    }

    #[view]
    public fun get_is_finalized(): bool acquires PoolInfo {
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        pool_info.is_finalized
    }

    #[view]
    public fun get_token_symbol_list(): vector<String> acquires TokenList, TokenRecord {
        let token_symbol_list = vector::empty<String>();
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let num_tokens = vector::length(&token_list.token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow(&token_record.records, token_address);
            let token_symbol = record.symbol;
            vector::push_back(&mut token_symbol_list, token_symbol);
            i = i + 1;
        };
        token_symbol_list
    }

    #[view]
    public fun get_pool_balance(): vector<u64> acquires TokenList, TokenRecord {
        let token_balance_list = vector::empty<u64>();
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let num_tokens = vector::length(&token_list.token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow(&token_record.records, token_address);
            let token_balance = record.balance;
            vector::push_back(&mut token_balance_list, token_balance);
            i = i + 1;
        };
        token_balance_list
    }

    #[view]
    public fun get_token_denorm_list(): vector<u64> acquires TokenList, TokenRecord {
        let token_denorm_list = vector::empty<u64>();
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let num_tokens = vector::length(&token_list.token_list);
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow(&token_record.records, token_address);
            let token_denorm = record.denorm;
            vector::push_back(&mut token_denorm_list, token_denorm);
            i = i + 1;
        };
        token_denorm_list
    }

    #[view]
    public fun get_token_weight_list(): vector<u64> acquires TokenList, TokenRecord, PoolInfo {
        let token_weight_list = vector::empty<u64>();
        let token_list = borrow_global<TokenList>(@pool_addr);
        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let num_tokens = vector::length(&token_list.token_list);
        let total_weight = get_total_denormalized_weight();
        let i = 0;
        while (i < num_tokens) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow(&token_record.records, token_address);
            let token_denorm = record.denorm;
            let weight = token_denorm * BONE / total_weight;
            vector::push_back(&mut token_weight_list, weight);
            i = i + 1;
        };
        token_weight_list
    }

    #[view]
    public fun get_swap_fee(): u64 acquires PoolInfo {
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        pool_info.swap_fee
    }

    #[view]
    public fun get_spot_price(token_in_name: String, token_in_symbol: String, token_out_name: String, token_out_symbol: String): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        let token_in_address = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = Liquid_Staking_Token::get_fa_obj_address(token_out_name, token_out_symbol);   
         let (record_token_in_balance, record_token_in_denorm) = {
            let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
            let record_token_in_balance = record_token_in.balance;
            let record_token_in_denorm = record_token_in.denorm;
            (record_token_in_balance, record_token_in_denorm)
        };

        let (record_token_out_balance, record_token_out_denorm) = {
            let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
            let record_token_out_balance = record_token_out.balance;
            let record_token_out_denorm = record_token_out.denorm;
            (record_token_out_balance, record_token_out_denorm)
        };
        let spot_price = Pool_Math::calc_spot_price(
            record_token_in_balance,
            record_token_in_denorm,
            record_token_out_balance,
            record_token_out_denorm,
            pool_info.swap_fee,
        );
        spot_price
    }

    // ========================================= Helper Function ========================================

    // transfer amount from sender to pool
    fun pull_underlying(sender: &signer, amount: u64, name: String, symbol: String) {
        let sender_addr = signer::address_of(sender);
        let pool_address = @pool_addr;
        Liquid_Staking_Token::transfer(sender, sender_addr, pool_address, amount, name, symbol);
    }
    
    // transfer amount from pool to sender
    fun push_underlying(sender: &signer, amount: u64, name: String, symbol: String) {
        let sender_addr = signer::address_of(sender);
        let pool_address = @pool_addr;
        Liquid_Staking_Token::transfer(sender, pool_address, sender_addr, amount, name, symbol);
    }

    fun mint_and_push_pool_share(sender: &signer, to: address, amount: u64) {
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::mint(sender, to, amount, lpt_name, lpt_symbol);
    }

    fun pull_pool_share(sender: &signer, sender_addr: address, amount: u64) {
        let pool_address = @pool_addr;
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::transfer(sender, sender_addr, pool_address, amount, lpt_name, lpt_symbol);
    }

    fun burn_pool_share(sender: &signer, amount: u64) {
        let pool_address = @pool_addr;
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        Liquid_Staking_Token::burn(sender, pool_address, amount, lpt_name, lpt_symbol);
    }
    
    // ======================================= Unit Test =========================================


    #[test_only]
    public fun create_token_test(
        sender: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        initial_supply: u64,
    ): Object<Metadata> {
        Liquid_Staking_Token::create_fa(signer::address_of(sender), name, symbol, decimals, icon_uri, project_uri);
        Liquid_Staking_Token::mint(sender, signer::address_of(sender), initial_supply, name, symbol);
        let asset = Liquid_Staking_Token::get_metadata(name, symbol);
        asset 
    }

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_bind_and_unbind(admin: signer, creator: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo{
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init(&creator);
        init_module(&admin);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let usdt = create_token_test(
            &creator,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        let eth = create_token_test(
            &creator,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500, eth_name, eth_symbol);
        bind(&user1, 100, 50, usdt_name, usdt_symbol);
        bind(&user1, 150, 50, eth_name, eth_symbol);

        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let token_list = borrow_global<TokenList>(@pool_addr);
        let list_token_length = vector::length(&token_list.token_list);
        assert!(list_token_length == 2, ERR_TEST);

        let token_address = vector::borrow(&token_list.token_list, 0);
        let record = simple_map::borrow<address, Record>(&token_record.records, token_address);
        assert!(record.bound == true, ERR_TEST);
        assert!(record.index == 0, ERR_TEST);
        assert!(record.denorm == 50, ERR_TEST);
        assert!(record.balance == 100, ERR_TEST);
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        assert!(pool_info.total_weight == 100, ERR_TEST);

        let user1_usdt_balance = get_balance(user1_addr, usdt_name, usdt_symbol);
        assert!(user1_usdt_balance == 400, ERR_TEST);
        let user1_eth_balance = get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 350, ERR_TEST);

        let pool_address = @pool_addr;
        let pool_usdt_balance = get_balance(pool_address, usdt_name, usdt_symbol);
        assert!(pool_usdt_balance == 100, ERR_TEST);
        let pool_eth_balance = get_balance(pool_address, eth_name, eth_symbol);
        assert!(pool_eth_balance == 150, ERR_TEST);

        // unbind
        unbind(&user1, eth_name, eth_symbol);
        let token_record = borrow_global<TokenRecord>(@pool_addr);
        let token_list = borrow_global<TokenList>(@pool_addr);
        let list_token_length = vector::length(&token_list.token_list);
        assert!(list_token_length == 1, ERR_TEST);
        let pool_info = borrow_global<PoolInfo>(admin_addr);
        assert!(pool_info.total_weight == 50, ERR_TEST);

        let admin_eth_balance = get_balance(user1_addr, eth_name, eth_symbol);
        assert!(admin_eth_balance == 500, ERR_TEST);

        let pool_eth_balance = get_balance(@pool_addr, eth_name, eth_symbol);
        assert!(pool_eth_balance == 0, ERR_TEST);
    }

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    fun test_join_pool_and_exit_pool(admin: signer, creator: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init(&creator);
        init_module(&admin);
        // let lp_asset = init_supply(&sender, ASSET_SEED);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &creator,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500000000,
        );

        let eth = create_token_test(
            &creator,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500000000,
        );

        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500000000, eth_name, eth_symbol);
        bind(&user1, 100000000, 50, usdt_name, usdt_symbol);
        bind(&user1, 150000000, 50, eth_name, eth_symbol);

        let max_amounts_in: vector<u64> = vector[500000000, 500000000];
        let user1_usdt_balance = get_balance(user1_addr, usdt_name, usdt_symbol);
        assert!(user1_usdt_balance == 400000000, ERR_TEST);
        finalize(&admin);
        join_pool(&user1, 10000000, max_amounts_in);
        
        // sender hold 10% of pool share, so sender can claim 10 LPT and must deposit 10 Token 1 and 20 Token 2
        let user1_lpt_balance = get_balance(user1_addr, lpt_name, lpt_symbol);
        assert!(user1_lpt_balance == 10000000, ERR_TEST);
        let user1_usdt_balance = get_balance(user1_addr, usdt_name, usdt_symbol);
        // print(&user1_usdt_balance);
        assert!(user1_usdt_balance == 390000000, ERR_TEST);
        let user1_eth_balance = get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 335000000, ERR_TEST);

        // let pool_balance = primary_fungible_store::balance(sender_addr, asset);
        let min_amounts_out: vector<u64> = vector[0, 0];
        exit_pool(&user1, 10000000, min_amounts_out);
        let user1_lpt_balance = get_balance(user1_addr, lpt_name, lpt_symbol);
        assert!(user1_lpt_balance == 0, ERR_TEST);
        let user1_usdt_balance = get_balance(user1_addr, usdt_name, usdt_symbol);
        // print(&user1_usdt_balance);
        // assert!(user1_usdt_balance == 400000000, ERR_TEST);
        let user1_eth_balance = get_balance(user1_addr, eth_name, eth_symbol);
        // print(&user1_eth_balance);
        // assert!(user1_eth_balance == 350000000, ERR_TEST);
    
    }
    
    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_swap_exact_amount_in(admin: signer, creator: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init(&creator);
        init_module(&admin);
        // let lp_asset = init_supply(&sender, ASSET_SEED);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &creator,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        let eth = create_token_test(
            &creator,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500000000, eth_name, eth_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user2_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user2_addr, 500000000, eth_name, eth_symbol);

        bind(&user1, 100000000, 50, usdt_name, usdt_symbol);
        bind(&user1, 150000000, 50, eth_name, eth_symbol);
        let max_amounts_in: vector<u64> = vector[500000000, 500000000];
        finalize(&admin);
        join_pool(&user1, 10000000, max_amounts_in);
        let (token_amount_out, spot_price_after) = get_swap_exact_amount_in(
            signer::address_of(&user2),
            usdt_name,
            usdt_symbol,
            10000000,
            eth_name,
            eth_symbol,
            0,
            1000000
        );
        // print(&token_amount_out);
        swap(
            &user2,
            usdt_name,
            usdt_symbol,
            10000000,
            eth_name,
            eth_symbol,
            token_amount_out,
        );
        
        let user2_usdt_balance = get_balance(user2_addr, usdt_name, usdt_symbol);
        assert!(user2_usdt_balance == 490000000, ERR_TEST);
        let user2_eth_balance = get_balance(user2_addr, eth_name, eth_symbol);
        // print(&user2_eth_balance);
        assert!(user2_eth_balance == 513737405, ERR_TEST);
    } 

    #[test(admin = @pool_addr, creator = @lst_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_swap_extern_amount_in(admin: signer, creator: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        Liquid_Staking_Token::init(&creator);
        init_module(&admin);
        // let lp_asset = init_supply(&sender, ASSET_SEED);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &creator,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        let eth = create_token_test(
            &creator,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            1000000000,
        );

        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user1_addr, 500000000, eth_name, eth_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user2_addr, 500000000, usdt_name, usdt_symbol);
        Liquid_Staking_Token::transfer(&creator, signer::address_of(&creator), user2_addr, 500000000, eth_name, eth_symbol);

        bind(&user1, 100000000, 50, usdt_name, usdt_symbol);
        bind(&user1, 150000000, 50, eth_name, eth_symbol);
        let max_amounts_in: vector<u64> = vector[500000000, 500000000];
        finalize(&admin);
        join_pool(&user1, 10000000, max_amounts_in);
        let pool_amount_out = get_join_swap_extern_amount_in(
            signer::address_of(&user2),
            eth_name,
            eth_symbol,
            50000000,
            0,
        );
        // print(&token_amount_out);
        join_swap(
            &user2,
            eth_name,
            eth_symbol,
            50000000,
            pool_amount_out,
        );
        
        let user2_lpt_balance = get_balance(user2_addr, lpt_name, lpt_symbol);
        assert!(user2_lpt_balance == pool_amount_out, ERR_TEST);
        let user2_eth_balance = get_balance(user2_addr, eth_name, eth_symbol);
        // print(&user2_eth_balance);
        assert!(user2_eth_balance == 450000000, ERR_TEST);
    } 
}