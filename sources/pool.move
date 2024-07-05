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
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    const ERR_LIMIT_IN:u64 = 0;
    const ERR_TEST: u64 = 101;

    const ASSET_SEED: vector<u8> = b"LPT";
    const INIT_POOL_SUPPLY: u64 = 100 * 1000000;
    const BONE: u64 = 1000000;
    const MIN_FEE: u64 = 1;

    struct PoolInfo has key {
        total_weight: u64,
        swap_fee: u64,
    }

    struct Record has key, store {
        bound: bool,
        index: u64, 
        denorm: u64,
        balance: u64,
        seed: vector<u8>,
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
    
    // todo: sender or admin?
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
        };
        move_to(sender, pool_info);
        let name = string::utf8(b"LP Token");
        let symbol = string::utf8(b"LPT");
        let decimals = 6;
        let icon_uri = string::utf8(b"http://example.com/favicon.ico");
        let project_uri = string::utf8(b"http://example.com");
        initialize_object(sender, name, symbol, decimals, icon_uri, project_uri);
    }

    // Initialize metadata object and store the refs
    fun initialize_object(
        sender: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
    ) {
        let seed = *string::bytes(&symbol);
        let constructor_ref = &object::create_named_object(sender, seed);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            name, 
            symbol, 
            decimals, 
            icon_uri, 
            project_uri,           
        );
        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        let metadata_object_signer = object::generate_signer(constructor_ref);
        move_to(
            &metadata_object_signer,
            ManagedFungibleAsset {
                mint_ref,
                transfer_ref,
                burn_ref,
            }
        );
    }

    // =============================== Entry Function =====================================

    // mint and push LP Token to owner
    public entry fun finalize(sender: &signer) acquires ManagedFungibleAsset  {
        // todo: require pool size >= 2 token
        mint_and_push_pool_share(sender, signer::address_of(sender), INIT_POOL_SUPPLY);
    }

    public entry fun set_swap_fee(sender: &signer, swap_fee: u64) acquires PoolInfo {
        let pool_info = borrow_global_mut<PoolInfo>(signer::address_of(sender));
        pool_info.swap_fee = swap_fee;
    }

    // @todo: require token lengths not max bound
    public entry fun bind(sender: &signer, balance: u64, denorm: u64, seed: vector<u8>) acquires TokenRecord, TokenList, PoolInfo, ManagedFungibleAsset {

        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let record = Record {
            bound: true,
            index: vector::length(&token_list.token_list),
            denorm: 0, // denorm and balance will be validated
            balance: 0, //  and set by rebind
            seed: seed,
        };

        let token_address = get_object_address(sender_addr, seed);

        simple_map::add(&mut token_record.records, token_address, record);
        vector::push_back(&mut token_list.token_list, token_address);
        rebind(sender, balance, denorm, seed);
    }

    public entry fun rebind(sender: &signer, balance: u64, denorm: u64, seed: vector<u8>) acquires TokenRecord, TokenList, PoolInfo, ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);

        let token_address = get_object_address(sender_addr, seed);
        
        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_address);
        let pool_info = borrow_global_mut<PoolInfo>(sender_addr);

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
            pull_underlying(sender, balance - old_balance, seed);
        } else {
            pull_underlying(sender, old_balance - balance, seed);
        }

    }

    public entry fun unbind(sender: &signer, seed: vector<u8>) acquires TokenRecord, TokenList, PoolInfo, ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);

        let token_address = get_object_address(sender_addr, seed);
        
        // adjust the denorm and total weight
        let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_address);
        let pool_info = borrow_global_mut<PoolInfo>(sender_addr);

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

        // Temporarily release the mutable borrow of record
        let record_ound = record.bound;
        let record_balance = record.bound;
        let record_index = record.index;
        let record_denorm = record.denorm;
 
        let record_index = simple_map::borrow_mut<address, Record>(&mut token_record.records, address_index);
        record_index.index = index;
        vector::pop_back(&mut token_list.token_list);
        
        push_underlying(sender, token_balance, seed);
    }

    public entry fun swap_exact_amount_in(
        sender: &signer,
        seed_token_in: vector<u8>,
        token_amount_in: u64,
        seed_token_out: vector<u8>,
        min_amount_out: u64,
        max_price: u64,
    ) acquires TokenList, TokenRecord, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let (token_amount_out, spot_price_after) = get_swap_exact_amount_in(
            sender_addr,
            seed_token_in,
            token_amount_in,
            seed_token_out,
            min_amount_out,
            max_price,
        );
        pull_underlying(sender, token_amount_in, seed_token_in);
        push_underlying(sender, token_amount_out, seed_token_out);
    }

    public entry fun swap_exact_amount_out(
        sender: &signer,
        seed_token_in: vector<u8>,
        max_amount_in: u64,
        seed_token_out: vector<u8>,
        token_amount_out: u64,
        max_price: u64,
    ) acquires TokenList, TokenRecord, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let (token_amount_in, spot_price_after) = get_swap_exact_amount_out(
            sender_addr,
            seed_token_in,
            max_amount_in,
            seed_token_out,
            token_amount_out,
            max_price,
        );
        pull_underlying(sender, token_amount_in, seed_token_in);
        push_underlying(sender, token_amount_out, seed_token_out);
    }

    public entry fun join_swap_extern_amount_in (
        sender: &signer, 
        seed_token_in: vector<u8>,
        token_amount_in: u64,
        min_pool_amount_out: u64
    ) acquires TokenList, TokenRecord, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let (pool_amount_out) = get_join_swap_extern_amount_in(
            sender_addr, 
            seed_token_in,
            token_amount_in,
            min_pool_amount_out,
        );
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
        pull_underlying(sender, token_amount_in, seed_token_in);
    }

    public entry fun join_swap_pool_amount_out (
        sender: &signer,
        seed_token_in: vector<u8>,
        pool_amount_out: u64,
        max_amount_in: u64,
    ) acquires TokenList, TokenRecord, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let token_amount_in = get_join_swap_pool_amount_out (
            sender_addr,
            seed_token_in,
            pool_amount_out,
            max_amount_in,
        );
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
        pull_underlying(sender, token_amount_in, seed_token_in);
    }

    public entry fun exit_swap_pool_amount_in (
        sender: &signer,
        seed_token_out: vector<u8>,
        pool_amount_in: u64,
        min_amount_out: u64,
    ) acquires TokenList, TokenRecord, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let token_amount_out = get_exit_swap_pool_amount_in (
            sender_addr,
            seed_token_out,
            pool_amount_in,
            min_amount_out,
        );
        pull_pool_share(sender, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool_amount_in);
        push_underlying(sender, token_amount_out, seed_token_out);
    }

    public entry fun exit_swap_extern_amount_out (
        sender: &signer,
        seed_token_out: vector<u8>,
        token_amount_out: u64,
        max_pool_amount_in: u64,
    ) acquires TokenList, TokenRecord, PoolInfo {
        let sender_addr = signer::address_of(sender);
        let pool_amount_in = get_exit_swap_extern_amount_out(
            sender_addr,
            seed_token_out,
            token_amount_out,
            max_pool_amount_in,
        );
        pull_pool_share(sender, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool_amount_in);
        push_underlying(sender, token_amount_out, seed_token_out);
    }

    public entry fun mint(sender: &signer, to: address, amount: u64, seed: vector<u8>) acquires ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let asset = get_metadata(signer::address_of(sender), seed);
        let managed_fungble_asset = authorized_borrow_refs(sender, asset);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&managed_fungble_asset.mint_ref, amount);
        fungible_asset::deposit_with_ref(&managed_fungble_asset.transfer_ref, to_wallet, fa);
    }

    public entry fun transfer(sender: &signer, from: address, to: address, amount: u64, seed: vector<u8>) acquires ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let asset = get_metadata(sender_addr, seed);
        let transfer_ref = &authorized_borrow_refs(sender, asset).transfer_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = withdraw(from_wallet, amount, transfer_ref);
        deposit(to_wallet, fa, transfer_ref);
    }

    public entry fun burn(sender: &signer, from: address, amount: u64, seed: vector<u8>) acquires ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let asset = get_metadata(sender_addr, seed);
        let burn_ref = &authorized_borrow_refs(sender, asset).burn_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        fungible_asset::burn_from(burn_ref, from_wallet, amount);
    }

    public entry fun join_pool(sender: &signer, pool_amount_out: u64, max_amounts_in: vector<u64>) acquires TokenList, TokenRecord, ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let pool_total = get_total_supply(sender_addr);
        let ratio = pool_amount_out * BONE / pool_total;
        // print(&pool_amount_out);
        // print(&pool_total);
        // print(&ratio);
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global<TokenList>(sender_addr);
        let token_list_length = vector::length(&token_list.token_list);
        let i = 0;
        while (i < token_list_length) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, token_address);
            let max_amount_in = vector::borrow(&max_amounts_in, (i as u64));
            let token_seed = record.seed;
            // Amount In to deposit
            let token_amount_in = ratio * record.balance / BONE;
            assert!(token_amount_in <= *max_amount_in, ERR_LIMIT_IN);

            record.balance = record.balance + token_amount_in;
            pull_underlying(sender, token_amount_in, token_seed);
            i = i + 1;
        };
        
        // todo: mint and deposit LP Token to sender
        mint_and_push_pool_share(sender, sender_addr, pool_amount_out);
    }

    public entry fun exit_pool(sender: &signer, pool_amount_in: u64, min_amounts_out: vector<u64>) acquires TokenList, TokenRecord, ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let pool_total = get_total_supply(sender_addr);
        let ratio = pool_amount_in / pool_total;
        pull_pool_share(sender, sender_addr, pool_amount_in);
        burn_pool_share(sender, pool_amount_in);
        
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global<TokenList>(sender_addr);
        let token_list_length = vector::length(&token_list.token_list);
        let i = 0;
        while (i < token_list_length) {
            let token_address = vector::borrow(&token_list.token_list, (i as u64));
            let record = simple_map::borrow_mut<address, Record>(&mut token_record.records, token_address);
            let min_amount_out = vector::borrow(&min_amounts_out, (i as u64));
            let token_seed = record.seed;
            let token_amount_out = ratio * record.balance;
            record.balance = record.balance - token_amount_out;
            push_underlying(sender, token_amount_out, token_seed);
            i = i + 1;
        }
    }

    public fun get_total_weight(sender: &signer): u64 acquires PoolInfo {
        let sender_addr = signer::address_of(sender);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        pool_info.total_weight
    }

    public fun get_token_number(sender: &signer): u64 acquires TokenList {
        let sender_addr = signer::address_of(sender);
        let token_list = borrow_global<TokenList>(sender_addr);
        vector::length(&token_list.token_list)
    }
    // ========================================= View Function ==========================================

    #[view]
    public fun get_swap_exact_amount_in(
        sender_addr: address,
        seed_token_in: vector<u8>,
        token_amount_in: u64,
        seed_token_out: vector<u8>,
        min_amount_out: u64,
        max_price: u64,
    ): (u64, u64) acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let pool_info = borrow_global_mut<PoolInfo>(sender_addr);

        let token_in_address = get_object_address(sender_addr, seed_token_in);
        let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
       
        let token_out_address = get_object_address(sender_addr, seed_token_out);
        let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
        let spot_price_before = calc_spot_price(
            record_token_in.balance,
            record_token_in.denorm,
            record_token_out.balance,
            record_token_out.denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_before <= max_price, ERR_BAD_LIMIT_PRICE);

        let token_amount_out = calc_out_given_in(
            record_token_in.balance,
            record_token_in.denorm,
            record_token_out.balance,
            record_token_out.denorm,
            token_amount_in,
            pool_info.swap_fee,
        );
        assert!(token_amount_out >= min_amount_out, ERR_LIMIT_OUT);
        
        record_token_in.balance = record_token_in.balance - token_amount_in;
        record_token_out.balance = record_token_out.balance + token_amount_out;

        let spot_price_after = calc_spot_price(
            record_token_in.balance,
            record_token_in.denorm,
            record_token_out.balance,
            record_token_out.denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_after >= spot_price_after, ERR_MATH_APPROX);
        assert!(spot_price_after <= max_price, ERR_LIMIT_PRICE);

        (token_amount_out, spot_price_after)
    }

    #[view]
    public fun get_swap_exact_amount_out (
        sender_addr: address,
        seed_token_in: vector<u8>,
        max_amount_in: u64,
        seed_token_out: vector<u8>,
        token_amount_out: u64,
        max_price: u64,
    ): (u64, u64) acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let token_in_address = get_object_address(sender_addr, seed_token_in);
        let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
       
        let token_out_address = get_object_address(sender_addr, seed_token_out);
        let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_out_address);
        let spot_price_before = calc_spot_price(
            record_token_in.balance,
            record_token_in.denorm,
            record_token_out.balance,
            record_token_out.denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_before <= max_price, ERR_BAD_LIMIT_PRICE);
        let token_amount_in = calc_in_given_out(
            record_token_in.balance,
            record_token_in.denorm,
            record_token_out.balance,
            record_token_out.denorm,
            token_amount_out,
            pool_info.swap_fee,
        );
        assert!(token_amount_in <= max_amount_in, ERR_LIMIT_IN);

        record_token_in.balance = record_token_in.balance - token_amount_in;
        record_token_out.balance = record_token_out.balance + token_amount_out;
        let spot_price_after = calc_spot_price(
            record_token_in.balance,
            record_token_in.denorm,
            record_token_out.balance,
            record_token_out.denorm,
            pool_info.swap_fee,
        );
        assert!(spot_price_after >= spot_price_after, ERR_MATH_APPROX);
        assert!(spot_price_after <= max_price, ERR_LIMIT_PRICE);

        (token_amount_in, spot_price_after)
    }

    #[view]
    public fun get_join_swap_extern_amount_in (
        sender_addr: address,
        seed_token_in: vector<u8>, 
        token_amount_in: u64,
        min_pool_amount_out: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let token_in_address = get_object_address(sender_addr, seed_token_in);
        let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        let total_supply = get_total_supply(sender_addr);
        let pool_amount_out = calc_pool_out_given_single_in(
            record_token_in.balance,
            record_token_in.denorm,
            total_supply,
            pool_info.total_weight,
            token_amount_in,
            pool_info.swap_fee,
        );
        assert!(pool_amount_out >= min_pool_amount_out, ERR_LIMIT_OUT);
        record_token_in.balance = record_token_in.balance + token_amount_in;
        pool_amount_out
    }

    public fun get_join_swap_pool_amount_out (
        sender_addr: address,
        seed_token_in: vector<u8>,
        pool_amount_out: u64,
        max_amount_in: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let token_in_address = get_object_address(sender_addr, seed_token_in);
        let record_token_in = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        let total_supply = get_total_supply(sender_addr);
        let token_amount_in = calc_single_in_give_pool_out (
            record_token_in.balance,
            record_token_in.denorm,
            total_supply,
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
        seed_token_out: vector<u8>,
        pool_amount_in: u64,
        min_amount_out: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let token_out_address = get_object_address(sender_addr, seed_token_out);
        let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        let total_supply = get_total_supply(sender_addr);
        let token_amount_out = calc_single_out_given_pool_in (
            record_token_out.balance,
            record_token_out.denorm,
            total_supply,
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
        seed_token_out: vector<u8>,
        token_amount_out: u64,
        max_pool_amount_in: u64,
    ): u64 acquires TokenList, TokenRecord, PoolInfo {
        let token_record = borrow_global_mut<TokenRecord>(sender_addr);
        let token_list = borrow_global_mut<TokenList>(sender_addr);
        let token_out_address = get_object_address(sender_addr, seed_token_out);
        let record_token_out = simple_map::borrow_mut<address, Record>(&mut token_record.records, &token_in_address);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        let total_supply = get_total_supply(sender_addr);
        let pool_amount_in = calc_pool_in_given_single_out (
            record_token_out.balance,
            record_token_out.denorm,
            total_supply,
            pool_info.total_weight,
            token_amount_out,
            pool_info.swap_fee,
        );
        assert!(pool_amount_in <= max_pool_amount_in, ERR_LIMIT_IN);
        record_token_out.balance = record_token_out.balance -  token_amount_out;
        pool_amount_in
    }

    // ========================================= Helper Function ========================================

    fun get_total_supply(sender_addr: address): u64 {
        let asset = get_metadata(sender_addr, ASSET_SEED);
        let total_supply = fungible_asset::supply(asset);
        if(option::is_some(&total_supply)) {
            let value = option::borrow(&total_supply);
            let result = (*value as u64);
            result
        } else {
            0
        }
    }

    fun get_object_address(creator: address, seed: vector<u8>): address {
        object::create_object_address(&creator, seed)
    }

    // transfer amount from sender to pool
    fun pull_underlying(sender: &signer, amount: u64, seed: vector<u8>) acquires ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let pool_address = @pool_addr;
        transfer(sender, sender_addr, pool_address, amount, seed);
    }
    
    // transfer amount from pool to sender
    fun push_underlying(sender: &signer, amount: u64, seed: vector<u8>) acquires ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        let pool_address = @pool_addr;
        transfer(sender, pool_address, sender_addr, amount, seed);
    }

    fun mint_and_push_pool_share(sender: &signer, to: address, amount: u64) acquires ManagedFungibleAsset {
        mint(sender, to, amount, ASSET_SEED);
    }

    fun pull_pool_share(sender: &signer, sender_addr: address, amount: u64) acquires ManagedFungibleAsset {
        let pool_address = @pool_addr;
        transfer(sender, sender_addr, pool_address, amount, ASSET_SEED);
    }

    fun burn_pool_share(sender: &signer, amount: u64) acquires ManagedFungibleAsset {
        let pool_address = @pool_addr;
        burn(sender, pool_address, amount, ASSET_SEED);
    }

    fun deposit<T: key>(store: Object<T>, fa: FungibleAsset, transfer_ref: &TransferRef) {
        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    fun withdraw<T: key>(store: Object<T>, amount: u64, transfer_ref: &TransferRef): FungibleAsset {
        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }
    
    fun get_metadata(sender: address, seed: vector<u8>): Object<Metadata> {
        let asset_address = get_object_address(sender, seed);
        object::address_to_object<Metadata>(asset_address)
    }

    inline fun authorized_borrow_refs(owner: &signer, asset: Object<Metadata>): &ManagedFungibleAsset acquires ManagedFungibleAsset {
        // checkowner
        borrow_global<ManagedFungibleAsset>(object::object_address(&asset))
    }
    
    // ======================================= Unit Test =========================================

    #[test(sender = @pool_addr)]
    public fun test_transfer(sender: signer) acquires ManagedFungibleAsset {
        init_module(&sender);
        let sender_addr = signer::address_of(&sender);
        let receiver_addr = @0x123;
        mint(&sender, sender_addr, 100, ASSET_SEED);
        let asset = get_metadata(sender_addr, ASSET_SEED);
        let sender_balance = primary_fungible_store::balance(sender_addr, asset);
        assert!(sender_balance == 100, ERR_TEST);
        transfer(&sender, sender_addr, receiver_addr, 30, ASSET_SEED);
        let sender_balance = primary_fungible_store::balance(sender_addr, asset);
        let receiver_balance = primary_fungible_store::balance(receiver_addr, asset);
        assert!(sender_balance == 70, ERR_TEST);
        assert!(receiver_balance == 30, ERR_TEST);
        burn(&sender, sender_addr, 70, ASSET_SEED);
        let sender_balance = primary_fungible_store::balance(sender_addr, asset);
        assert!(sender_balance == 0, ERR_TEST);
    }

    #[test_only]
    public fun init_supply(sender: &signer, seed: vector<u8>, initial_supply: u64): Object<Metadata> acquires ManagedFungibleAsset {
        let sender_addr = signer::address_of(sender);
        mint(sender, sender_addr, initial_supply, seed);
        let asset = get_metadata(sender_addr, seed);
        let sender_balance = primary_fungible_store::balance(sender_addr, asset);
        assert!(sender_balance == initial_supply, ERR_TEST);
        asset
    }

    #[test_only]
    public fun create_token_test(
        sender: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        initial_supply: u64,
    ): Object<Metadata> acquires ManagedFungibleAsset {
        initialize_object(sender, name, symbol, decimals, icon_uri, project_uri);
        let seed = *string::bytes(&symbol);
        init_supply(sender, seed, initial_supply)
    }

    #[test_only]
    const ASSET_SEED_1: vector<u8> = b"PT1";
    const ASSET_SEED_2: vector<u8> = b"PT2";

    #[test(sender = @0x3, pool = @pool_addr)]
    public fun test_bind_and_unbind(sender: signer, pool: signer) acquires TokenList, TokenRecord, PoolInfo, ManagedFungibleAsset{
        let sender_addr = signer::address_of(&sender);
        let pool_addr = signer::address_of(&pool);
        init_module(&sender);
        let lp_asset = init_supply(&sender, ASSET_SEED, 500);
        let token_1_asset = create_token_test(
            &sender,
            string::utf8(b"Pool Test Token 1"),
            string::utf8(b"PT1"),
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        let token_2_asset = create_token_test(
            &sender,
            string::utf8(b"Pool Test Token 2"),
            string::utf8(b"PT2"),
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );
        
        bind(&sender, 100, 50, ASSET_SEED_1);
        bind(&sender, 200, 50, ASSET_SEED_2);

        let token_record = borrow_global<TokenRecord>(sender_addr);
        let token_list = borrow_global<TokenList>(sender_addr);
        let list_token_length = vector::length(&token_list.token_list);
        assert!(list_token_length == 2, ERR_TEST);

        let token_address = vector::borrow(&token_list.token_list, 0);
        let record = simple_map::borrow<address, Record>(&token_record.records, token_address);
        assert!(record.bound == true, ERR_TEST);
        assert!(record.index == 0, ERR_TEST);
        assert!(record.denorm == 50, ERR_TEST);
        assert!(record.balance == 100, ERR_TEST);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        assert!(pool_info.total_weight == 100, ERR_TEST);

        let sender_balance = primary_fungible_store::balance(sender_addr, token_1_asset);
        assert!(sender_balance == 400, ERR_TEST);

        let pool_balance = primary_fungible_store::balance(pool_addr, token_1_asset);
        assert!(pool_balance == 100, ERR_TEST);


        // unbind
        unbind(&sender, ASSET_SEED_2);
        let token_record = borrow_global<TokenRecord>(sender_addr);
        let token_list = borrow_global<TokenList>(sender_addr);
        let list_token_length = vector::length(&token_list.token_list);
        assert!(list_token_length == 1, ERR_TEST);
        let pool_info = borrow_global<PoolInfo>(sender_addr);
        assert!(pool_info.total_weight == 50, ERR_TEST);

        let sender_balance = primary_fungible_store::balance(sender_addr, token_2_asset);
        assert!(sender_balance == 500, ERR_TEST);

        let pool_balance = primary_fungible_store::balance(pool_addr, token_2_asset);
        assert!(pool_balance == 0, ERR_TEST);
    }

    #[test(sender = @0x3, user2 = @0x4, pool = @pool_addr)]
    fun test_join_pool_and_exit_pool(sender: signer, user2: signer, pool: signer) acquires TokenList, TokenRecord, PoolInfo, ManagedFungibleAsset {
        let sender_addr = signer::address_of(&sender);
        let pool_addr = signer::address_of(&pool);
        init_module(&sender);
        // let lp_asset = init_supply(&sender, ASSET_SEED);
        let token_1_asset = create_token_test(
            &sender,
            string::utf8(b"Pool Test Token 1"),
            string::utf8(b"PT1"),
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        let token_2_asset = create_token_test(
            &sender,
            string::utf8(b"Pool Test Token 2"),
            string::utf8(b"PT2"),
            6,
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            500,
        );

        bind(&sender, 100, 50, ASSET_SEED_1);
        bind(&sender, 200, 50, ASSET_SEED_2);
        let max_amounts_in: vector<u64> = vector[500, 500];
        let sender_balance_asset_1 = primary_fungible_store::balance(sender_addr, token_1_asset);
        assert!(sender_balance_asset_1 == 400, ERR_TEST);
        finalize(&sender);
        join_pool(&sender, 10, max_amounts_in);
        
        // sender hold 10% of pool share, so sender can claim 10 LPT and must deposit 10 Token 1 and 20 Token 2
        let sender_balance_asset_1 = primary_fungible_store::balance(sender_addr, token_1_asset);
        assert!(sender_balance_asset_1 == 390, ERR_TEST);

        let sender_balance_asset_2 = primary_fungible_store::balance(sender_addr, token_2_asset);
        assert!(sender_balance_asset_2 == 280, ERR_TEST);

        // let pool_balance = primary_fungible_store::balance(sender_addr, asset);

    }
    

}