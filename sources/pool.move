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
    use pool_math_addr::Pool_Math;

    const ERR_LIMIT_IN:u64 = 0;
    const ERR_TEST: u64 = 101;
    const ERR_BAD_LIMIT_PRICE:u64 = 1;
    const ERR_LIMIT_OUT:u64 = 2;
    const ERR_MATH_APPROX:u64 = 3;
    const ERR_LIMIT_PRICE:u64 = 4;

    const INIT_POOL_SUPPLY: u64 = 100;
    const BONE: u64 = 1000000;
    const MIN_FEE: u64 = 1;

    struct LST has key {
        fa_generator_extend_ref: ExtendRef,
    }

    struct PoolInfo has key {
        total_weight: u64,
        swap_fee: u64,
    }

    struct Record has key, store {
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

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct ManagedFungibleAsset has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
    }
    
    fun init_module(sender: &signer) acquires LST {
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
        };
        move_to(sender, pool_info);

        let constructor_ref = object::create_named_object(sender, b"FA Generator");
        let fa_generator_extend_ref = object::generate_extend_ref(&constructor_ref);
        let lst = LST {
            fa_generator_extend_ref: fa_generator_extend_ref,
        };
        move_to(sender, lst);

        let name = string::utf8(b"LP Token");
        let symbol = string::utf8(b"LPT");
        let decimals = 6;
        let icon_uri = string::utf8(b"http://example.com/favicon.ico");
        let project_uri = string::utf8(b"http://example.com");
        create_fa(sender, name, symbol, decimals, icon_uri, project_uri);
    }

    public entry fun create_fa(
        sender: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
    ) acquires LST {
        let lst = borrow_global_mut<LST>(@pool_addr);
        let fa_generator_signer = object::generate_signer_for_extending(&lst.fa_generator_extend_ref);
        let fa_key_seed = *string::bytes(&name);
        vector::append(&mut fa_key_seed, b"-");
        vector::append(&mut fa_key_seed, *string::bytes(&symbol));
        let fa_obj_constructor_ref = &object::create_named_object(&fa_generator_signer, fa_key_seed);
        let fa_obj_signer = object::generate_signer(fa_obj_constructor_ref);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            fa_obj_constructor_ref,
            option::none(),
            name, 
            symbol, 
            decimals, 
            icon_uri, 
            project_uri,           
        );
        let mint_ref = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);
        move_to(
            &fa_obj_signer,
            ManagedFungibleAsset {
                mint_ref,
                transfer_ref,
                burn_ref,
            }
        );

    }

    // =============================== Entry Function =====================================

    // mint and push LP Token to owner
    public entry fun finalize(sender: &signer) acquires ManagedFungibleAsset, LST {
        // todo: require pool size >= 2 token
        mint_and_push_pool_share(sender, signer::address_of(sender), INIT_POOL_SUPPLY);
    }

    public entry fun set_swap_fee(sender: &signer, swap_fee: u64) acquires PoolInfo {
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        pool_info.swap_fee = swap_fee;
    }

    // @todo: require token lengths not max bound
    public entry fun bind(sender: &signer, balance: u64, denorm: u64, name: String, symbol: String) acquires TokenRecord, TokenList, PoolInfo, ManagedFungibleAsset, LST {

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

        let token_address = get_fa_obj_address(name, symbol);
        simple_map::add(&mut token_record.records, token_address, record);
        vector::push_back(&mut token_list.token_list, token_address);
        rebind(sender, balance, denorm, name, symbol);
    }

    public entry fun rebind(sender: &signer, balance: u64, denorm: u64, name: String, symbol: String) acquires TokenRecord, TokenList, PoolInfo, ManagedFungibleAsset, LST {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);

        let token_address = get_fa_obj_address(name, symbol);
        
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

    public entry fun unbind(sender: &signer, name: String, symbol: String) acquires TokenRecord, TokenList, PoolInfo, ManagedFungibleAsset, LST {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);

        let token_address = get_fa_obj_address(name, symbol);
        
        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_address);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);

        let token_balance = record.balance;
        pool_info.total_weight = pool_info.total_weight - record.denorm;

        // swap the token-to-unbind with the last token
        // then delete the last token
        let index = record.index;
        let last = vector::length(&token_list.token_list) - 1;
        vector::swap(&mut token_list.token_list, index, last);
        let address_index = vector::borrow(&token_list.token_list, index);  
        record.bound = false;
        record.balance = 0;
        record.index = 0;
        record.denorm = 0;
 
        let record_index = simple_map::borrow_mut<address, Record>(&mut token_record.records, address_index);
        record_index.index = index;
        vector::pop_back(&mut token_list.token_list);
        
        push_underlying(sender, token_balance, name, symbol);
    }

    public entry fun swap_exact_amount_in(
        sender: &signer,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u64,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u64,
    ) acquires LST, ManagedFungibleAsset {
        pull_underlying(sender, token_amount_in, token_in_name, token_in_symbol);
        push_underlying(sender, token_amount_out, token_out_name, token_out_symbol);
    }

    public entry fun swap_exact_amount_out(
        sender: &signer,
        token_in_name: String,
        token_in_symbol: String,
        token_amount_in: u64,
        token_out_name: String,
        token_out_symbol: String,
        token_amount_out: u64,
    ) acquires LST, ManagedFungibleAsset {
        pull_underlying(sender, token_amount_in, token_in_name, token_in_symbol);
        push_underlying(sender, token_amount_out, token_out_name, token_out_symbol);
    }

    // public entry fun join_swap_extern_amount_in (
    //     sender: &signer, 
    //     seed_token_in: vector<u8>,
    //     token_amount_in: u64,
    //     min_pool_amount_out: u64
    // ) acquires TokenList, TokenRecord, PoolInfo {
    //     let sender_addr = signer::address_of(sender);
    //     let (pool_amount_out) = get_join_swap_extern_amount_in(
    //         sender_addr, 
    //         seed_token_in,
    //         token_amount_in,
    //         min_pool_amount_out,
    //     );
    //     mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
    //     pull_underlying(sender, token_amount_in, seed_token_in);
    // }

    // public entry fun join_swap_pool_amount_out (
    //     sender: &signer,
    //     seed_token_in: vector<u8>,
    //     pool_amount_out: u64,
    //     max_amount_in: u64,
    // ) acquires TokenList, TokenRecord, PoolInfo {
    //     let sender_addr = signer::address_of(sender);
    //     let token_amount_in = get_join_swap_pool_amount_out (
    //         sender_addr,
    //         seed_token_in,
    //         pool_amount_out,
    //         max_amount_in,
    //     );
    //     mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
    //     pull_underlying(sender, token_amount_in, seed_token_in);
    // }

    // public entry fun exit_swap_pool_amount_in (
    //     sender: &signer,
    //     seed_token_out: vector<u8>,
    //     pool_amount_in: u64,
    //     min_amount_out: u64,
    // ) acquires TokenList, TokenRecord, PoolInfo {
    //     let sender_addr = signer::address_of(sender);
    //     let token_amount_out = get_exit_swap_pool_amount_in (
    //         sender_addr,
    //         seed_token_out,
    //         pool_amount_in,
    //         min_amount_out,
    //     );
    //     pull_pool_share(sender, sender_addr, pool_amount_in);
    //     burn_pool_share(sender, pool_amount_in);
    //     push_underlying(sender, token_amount_out, seed_token_out);
    // }

    // public entry fun exit_swap_extern_amount_out (
    //     sender: &signer,
    //     seed_token_out: vector<u8>,
    //     token_amount_out: u64,
    //     max_pool_amount_in: u64,
    // ) acquires TokenList, TokenRecord, PoolInfo {
    //     let sender_addr = signer::address_of(sender);
    //     let pool_amount_in = get_exit_swap_extern_amount_out(
    //         sender_addr,
    //         seed_token_out,
    //         token_amount_out,
    //         max_pool_amount_in,
    //     );
    //     pull_pool_share(sender, sender_addr, pool_amount_in);
    //     burn_pool_share(sender, pool_amount_in);
    //     push_underlying(sender, token_amount_out, seed_token_out);
    // }

    public entry fun mint(sender: &signer, to: address, amount: u64, name: String, symbol: String) acquires LST, ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let asset = get_metadata(name, symbol);
        let managed_fungble_asset = authorized_borrow_refs(sender, asset);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&managed_fungble_asset.mint_ref, amount);
        fungible_asset::deposit_with_ref(&managed_fungble_asset.transfer_ref, to_wallet, fa);
    }

    public entry fun transfer(sender: &signer, from: address, to: address, amount: u64, name: String, symbol: String) acquires LST, ManagedFungibleAsset {
        let asset = get_metadata(name, symbol);
        let transfer_ref = &authorized_borrow_refs(sender, asset).transfer_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = withdraw(from_wallet, amount, transfer_ref);
        deposit(to_wallet, fa, transfer_ref);
    }

    public entry fun burn(sender: &signer, from: address, amount: u64, name: String, symbol: String) acquires LST, ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let asset = get_metadata(name, symbol);
        let burn_ref = &authorized_borrow_refs(sender, asset).burn_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        fungible_asset::burn_from(burn_ref, from_wallet, amount);
    }

    public entry fun join_pool(sender: &signer, pool_amount_out: u64, max_amounts_in: vector<u64>) acquires TokenList, TokenRecord, ManagedFungibleAsset, LST {
        let sender_addr = signer::address_of(sender);
        let pool_total = get_total_supply_lpt();
        let ratio = pool_amount_out * BONE / pool_total;
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
            let token_amount_in = ratio * record.balance / BONE;
            assert!(token_amount_in <= *max_amount_in, ERR_LIMIT_IN);

            record.balance = record.balance + token_amount_in;
            pull_underlying(sender, token_amount_in, name, symbol);
            i = i + 1;
        };
        
        // todo: mint and deposit LP Token to sender
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
    }

    public entry fun exit_pool(sender: &signer, pool_amount_in: u64, min_amounts_out: vector<u64>) acquires TokenList, TokenRecord, ManagedFungibleAsset, LST {
        let sender_addr = signer::address_of(sender);
        let pool_total = get_total_supply_lpt();
        let ratio = pool_amount_in / pool_total;
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
            let token_amount_out = ratio * record.balance;
            record.balance = record.balance - token_amount_out;
            push_underlying(sender, token_amount_out, name, symbol);
            i = i + 1;
        }
    }

    public fun get_total_weight(sender: &signer): u64 acquires PoolInfo {
        let pool_info = borrow_global<PoolInfo>(@pool_addr);
        pool_info.total_weight
    }

    public fun get_token_number(sender: &signer): u64 acquires TokenList {
        let token_list = borrow_global<TokenList>(@pool_addr);
        vector::length(&token_list.token_list)
    }
    // ========================================= View Function ==========================================

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
    ): (u64, u64) acquires TokenList, TokenRecord, PoolInfo, LST {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);

        let token_in_address = get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = get_fa_obj_address(token_out_name, token_out_symbol);    
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
    ): (u64, u64) acquires TokenList, TokenRecord, PoolInfo, LST {
        let token_record = borrow_global_mut<TokenRecord>(@pool_addr);
        let token_list = borrow_global_mut<TokenList>(@pool_addr);
        let pool_info = borrow_global_mut<PoolInfo>(@pool_addr);
        let token_in_address = get_fa_obj_address(token_in_name, token_in_symbol);
        let token_out_address = get_fa_obj_address(token_out_name, token_out_symbol);    
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

    // #[view]
    // public fun get_join_swap_extern_amount_in (
    //     sender_addr: address,
    //     seed_token_in: vector<u8>, 
    //     token_amount_in: u64,
    //     min_pool_amount_out: u64,
    // ): u64 acquires TokenList, TokenRecord, PoolInfo {
    //     let token_record = borrow_global_mut<TokenRecord>(sender_addr);
    //     let token_list = borrow_global_mut<TokenList>(sender_addr);
    //     let token_in_address = get_fa_obj_address(sender_addr, seed_token_in);
    //     let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
    //     let pool_info = borrow_global<PoolInfo>(sender_addr);
    //     let total_supply = get_total_supply(sender_addr);
    //     let pool_amount_out = calc_pool_out_given_single_in(
    //         record_token_in.balance,
    //         record_token_in.denorm,
    //         total_supply,
    //         pool_info.total_weight,
    //         token_amount_in,
    //         pool_info.swap_fee,
    //     );
    //     assert!(pool_amount_out >= min_pool_amount_out, ERR_LIMIT_OUT);
    //     record_token_in.balance = record_token_in.balance + token_amount_in;
    //     pool_amount_out
    // }

    // public fun get_join_swap_pool_amount_out (
    //     sender_addr: address,
    //     seed_token_in: vector<u8>,
    //     pool_amount_out: u64,
    //     max_amount_in: u64,
    // ): u64 acquires TokenList, TokenRecord, PoolInfo {
    //     let token_record = borrow_global_mut<TokenRecord>(sender_addr);
    //     let token_list = borrow_global_mut<TokenList>(sender_addr);
    //     let token_in_address = get_fa_obj_address(sender_addr, seed_token_in);
    //     let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
    //     let pool_info = borrow_global<PoolInfo>(sender_addr);
    //     let total_supply = get_total_supply(sender_addr);
    //     let token_amount_in = calc_single_in_give_pool_out (
    //         record_token_in.balance,
    //         record_token_in.denorm,
    //         total_supply,
    //         pool_info.total_weight,
    //         pool_amount_out,
    //         pool_info.swap_fee,
    //     );
    //     assert!(token_amount_in <= max_amount_in, ERR_LIMIT_IN);
    //     record_token_in.balance = record_token_in.balance + token_amount_in;
    //     token_amount_in
    // }

    // #[view] 
    // public fun get_exit_swap_pool_amount_in (
    //     sender_addr: address,
    //     seed_token_out: vector<u8>,
    //     pool_amount_in: u64,
    //     min_amount_out: u64,
    // ): u64 acquires TokenList, TokenRecord, PoolInfo {
    //     let token_record = borrow_global_mut<TokenRecord>(sender_addr);
    //     let token_list = borrow_global_mut<TokenList>(sender_addr);
    //     let token_out_address = get_fa_obj_address(sender_addr, seed_token_out);
    //     let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
    //     let pool_info = borrow_global<PoolInfo>(sender_addr);
    //     let total_supply = get_total_supply(sender_addr);
    //     let token_amount_out = calc_single_out_given_pool_in (
    //         record_token_out.balance,
    //         record_token_out.denorm,
    //         total_supply,
    //         pool_info.total_weight,
    //         pool_amount_in,
    //         pool_info.swap_fee
    //     );
    //     assert!(token_amount_out >= min_amount_out, ERR_LIMIT_OUT);
    //     record_token_out.balance = record_token_out.balance - token_amount_out;
    //     token_amount_out
    // }

    // #[view]
    // public fun get_exit_swap_extern_amount_out(
    //     sender_addr: address,
    //     seed_token_out: vector<u8>,
    //     token_amount_out: u64,
    //     max_pool_amount_in: u64,
    // ): u64 acquires TokenList, TokenRecord, PoolInfo {
    //     let token_record = borrow_global_mut<TokenRecord>(sender_addr);
    //     let token_list = borrow_global_mut<TokenList>(sender_addr);
    //     let token_out_address = get_fa_obj_address(sender_addr, seed_token_out);
    //     let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
    //     let pool_info = borrow_global<PoolInfo>(sender_addr);
    //     let total_supply = get_total_supply(sender_addr);
    //     let pool_amount_in = calc_pool_in_given_single_out (
    //         record_token_out.balance,
    //         record_token_out.denorm,
    //         total_supply,
    //         pool_info.total_weight,
    //         token_amount_out,
    //         pool_info.swap_fee,
    //     );
    //     assert!(pool_amount_in <= max_pool_amount_in, ERR_LIMIT_IN);
    //     record_token_out.balance = record_token_out.balance -  token_amount_out;
    //     pool_amount_in
    // }

    #[view]
    public fun get_lpt_address(): address acquires LST {
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        get_fa_obj_address(lpt_name, lpt_symbol)
    }

    #[view] 
    public fun get_total_supply_lpt(): u64 acquires LST {
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        get_total_supply(lpt_name, lpt_symbol)
    }

    #[view]
    public fun get_total_supply(name: String, symbol: String): u64 acquires LST{
        let asset = get_metadata(name, symbol);
        let total_supply = fungible_asset::supply(asset);
        if(option::is_some(&total_supply)) {
            let value = option::borrow(&total_supply);
            let result = (*value as u64);
            result
        } else {
            0
        }
    }

    #[view]
    public fun get_balance(sender_addr: address, name: String, symbol: String): u64 acquires LST {
        let object_address = get_fa_obj_address(name, symbol);
        // print(&name);
        // print(&symbol);
        // print(&object_address);
        let fa_metadata_obj: Object<Metadata> = object::address_to_object(object_address);
        primary_fungible_store::balance(sender_addr, fa_metadata_obj)
    }

    // ========================================= Helper Function ========================================

    fun get_fa_obj_address(name: String, symbol: String): address acquires LST {
        let lst = borrow_global<LST>(@pool_addr);
        let fa_generator_address = object::address_from_extend_ref(&lst.fa_generator_extend_ref);
        let fa_key_seed = *string::bytes(&name);
        vector::append(&mut fa_key_seed, b"-");
        vector::append(&mut fa_key_seed, *string::bytes(&symbol));
        object::create_object_address(&fa_generator_address, fa_key_seed)
    }

    // transfer amount from sender to pool
    fun pull_underlying(sender: &signer, amount: u64, name: String, symbol: String) acquires ManagedFungibleAsset, LST {
        let sender_addr = signer::address_of(sender);
        let pool_address = @pool_addr;
        transfer(sender, sender_addr, pool_address, amount, name, symbol);
    }
    
    // transfer amount from pool to sender
    fun push_underlying(sender: &signer, amount: u64, name: String, symbol: String) acquires ManagedFungibleAsset, LST {
        let sender_addr = signer::address_of(sender);
        let pool_address = @pool_addr;
        transfer(sender, pool_address, sender_addr, amount, name, symbol);
    }

    fun mint_and_push_pool_share(sender: &signer, to: address, amount: u64) acquires ManagedFungibleAsset, LST{
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        mint(sender, to, amount, lpt_name, lpt_symbol);
    }

    fun pull_pool_share(sender: &signer, sender_addr: address, amount: u64) acquires ManagedFungibleAsset, LST {
        let pool_address = @pool_addr;
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        transfer(sender, sender_addr, pool_address, amount, lpt_name, lpt_symbol);
    }

    fun burn_pool_share(sender: &signer, amount: u64) acquires ManagedFungibleAsset, LST {
        let pool_address = @pool_addr;
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        burn(sender, pool_address, amount, lpt_name, lpt_symbol);
    }

    fun deposit<T: key>(store: Object<T>, fa: FungibleAsset, transfer_ref: &TransferRef) {
        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    fun withdraw<T: key>(store: Object<T>, amount: u64, transfer_ref: &TransferRef): FungibleAsset {
        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }
    
    public fun get_metadata(name: String, symbol: String): Object<Metadata> acquires LST {
        let asset_address = get_fa_obj_address(name, symbol);
        // print(&name);
        // print(&symbol);
        // print(&asset_address);
        object::address_to_object(asset_address)
    }

    inline fun authorized_borrow_refs(owner: &signer, asset: Object<Metadata>): &ManagedFungibleAsset acquires ManagedFungibleAsset {
        // checkowner
        borrow_global<ManagedFungibleAsset>(object::object_address(&asset))
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
    ): Object<Metadata> acquires LST, ManagedFungibleAsset {
        create_fa(sender, name, symbol, decimals, icon_uri, project_uri);
        mint(sender, signer::address_of(sender), initial_supply, name, symbol);
        let asset = get_metadata(name, symbol);
        asset 
    }

    #[test(admin = @pool_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_bind_and_unbind(admin: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo, ManagedFungibleAsset, LST {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        init_module(&admin);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );
        
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

    #[test(admin = @pool_addr, user1 = @0x123, user2 = @0x1234)]
    fun test_join_pool_and_exit_pool(admin: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo, ManagedFungibleAsset, LST {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        init_module(&admin);
        // let lp_asset = init_supply(&sender, ASSET_SEED);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        bind(&user1, 100, 50, usdt_name, usdt_symbol);
        bind(&user1, 150, 50, eth_name, eth_symbol);

        let max_amounts_in: vector<u64> = vector[500, 500];
        let user1_usdt_balance = get_balance(user1_addr, usdt_name, usdt_symbol);
        assert!(user1_usdt_balance == 400, ERR_TEST);
        finalize(&admin);
        join_pool(&user1, 10, max_amounts_in);
        
        // sender hold 10% of pool share, so sender can claim 10 LPT and must deposit 10 Token 1 and 20 Token 2
        let user1_lpt_balance = get_balance(user1_addr, lpt_name, lpt_symbol);
        assert!(user1_lpt_balance == 10, ERR_TEST);
        let user1_usdt_balance = get_balance(user1_addr, usdt_name, usdt_symbol);
        assert!(user1_usdt_balance == 390, ERR_TEST);
        let user1_eth_balance = get_balance(user1_addr, eth_name, eth_symbol);
        assert!(user1_eth_balance == 335, ERR_TEST);

        // let pool_balance = primary_fungible_store::balance(sender_addr, asset);
    
    }
    
    #[test(admin = @pool_addr, user1 = @0x123, user2 = @0x1234)]
    public fun test_swap_exact_amount_in(admin: signer, user1: signer, user2: signer) acquires TokenList, TokenRecord, PoolInfo, ManagedFungibleAsset, LST {
        let admin_addr = signer::address_of(&admin);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        init_module(&admin);
        // let lp_asset = init_supply(&sender, ASSET_SEED);
        let usdt_name = string::utf8(b"USD Tether");
        let usdt_symbol = string::utf8(b"USDT");
        let eth_name = string::utf8(b"Ethereum");
        let eth_symbol = string::utf8(b"ETH");
        let lpt_name = string::utf8(b"LP Token");
        let lpt_symbol = string::utf8(b"LPT");
        let usdt = create_token_test(
            &user1,
            usdt_name,
            usdt_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        let eth = create_token_test(
            &user1,
            eth_name,
            eth_symbol,
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );
        mint(&user2, user2_addr, 500, usdt_name, usdt_symbol);
        mint(&user2, user2_addr, 500, eth_name, eth_symbol);

        bind(&user1, 100, 50, usdt_name, usdt_symbol);
        bind(&user1, 150, 50, eth_name, eth_symbol);
        let max_amounts_in: vector<u64> = vector[500, 500];
        finalize(&admin);
        // join_pool(&user1, 10, max_amounts_in);
        let (token_amount_out, spot_price_after) = get_swap_exact_amount_in(
            signer::address_of(&user2),
            usdt_name,
            usdt_symbol,
            10,
            eth_name,
            eth_symbol,
            0,
            1000000
        );
        // print(&token_amount_out);
        swap_exact_amount_in(
            &user2,
            usdt_name,
            usdt_symbol,
            10,
            eth_name,
            eth_symbol,
            token_amount_out,
        );
        
        let user2_usdt_balance = get_balance(user2_addr, usdt_name, usdt_symbol);
        assert!(user2_usdt_balance == 490, ERR_TEST);
        let user2_eth_balance = get_balance(user2_addr, eth_name, eth_symbol);
        assert!(user2_eth_balance == 514, ERR_TEST);
    } 
}