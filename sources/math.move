module pool_addr::Pool_Math {
    use std::debug::print;
    use std::string::{Self, String, utf8};

    const BONE:u64 = 1000000;
    const EXIT_FEE: u64 = 0;

    const ERR_MATH: u64 = 1;

    public fun hellworld(): String {
        let check = string::utf8(b"hello world");
        check
    }

    public fun calc_spot_price (
        token_balance_in: u64,
        token_weight_in: u64,
        token_balance_out: u64,
        token_weight_out: u64,
        swap_fee: u64,
    ): u64 {
        let numer = bdiv(token_balance_in, token_weight_in);
        let denom = bdiv(token_balance_out, token_weight_out);
        let ratio = bdiv(numer, denom);
        let scale = bdiv(BONE, bsub(BONE, swap_fee));
        let spot_price = bmul(ratio, scale);
        spot_price
    }

    public fun calc_out_given_in(
        token_balance_in: u64,
        token_weight_in: u64,
        token_balance_out: u64,
        token_weight_out: u64,
        token_amount_in: u64,
        swap_fee: u64,
    ): u64 {
        let weight_ratio = bdiv(token_weight_in, token_weight_out);
        let adjusted_in = bsub(BONE, swap_fee);
        adjusted_in = bmul(token_amount_in, adjusted_in);
        let y = bdiv(token_balance_in, badd(token_balance_in, adjusted_in));
        let check = string::utf8(b"check");
        let foo = bpow(y, weight_ratio);
        let bar = bsub(BONE, foo);
        let token_amount_out = bmul(token_balance_out, bar);
        token_amount_out
    }

    public fun calc_in_given_out(
        token_balance_in: u64,
        token_weight_in: u64,
        token_balance_out: u64,
        token_weight_out: u64,
        token_amount_out: u64,
        swap_fee: u64
    ): u64 {
        let weight_ratio = bdiv(token_weight_out, token_weight_in);
        let diff = bsub(token_balance_out, token_amount_out);
        let y = bdiv(token_balance_out, diff);
        let foo = bpow(y, weight_ratio);
        foo = bsub(foo, BONE);
        let token_amount_in = bsub(BONE, swap_fee);
        token_amount_in = bdiv(bmul(token_balance_in, foo), token_amount_in);
        token_amount_in
    }

    public fun calc_pool_out_given_single_in(
        token_balance_in: u64,
        token_weight_in: u64,
        pool_supply: u64,
        total_weight: u64,
        token_amount_in: u64,
        swap_fee: u64
    ): u64 {
        let normalized_weight = bdiv(token_weight_in, total_weight);
        let zaz = bmul(bsub(BONE, normalized_weight), swap_fee);
        let token_amount_in_after_fee = bmul(token_amount_in, bsub(BONE, zaz));

        let new_token_balance_in = badd(token_balance_in, token_amount_in_after_fee);
        let token_in_ratio = bdiv(new_token_balance_in, token_balance_in);

        let pool_ratio = bpow(token_in_ratio, normalized_weight);
        let new_pool_supply = bmul(pool_ratio, pool_supply);
        let pool_amount_out = bsub(new_pool_supply, pool_supply);
        pool_amount_out
    }

    public fun calc_single_in_given_pool_out(
        token_balance_in: u64,
        token_weight_in: u64,
        pool_supply: u64,
        total_weight: u64,
        pool_amount_out: u64,
        swap_fee: u64
    ): u64 {
        let normalized_weight = bdiv(token_weight_in, total_weight);
        let new_pool_supply = badd(pool_supply, pool_amount_out);
        let pool_ratio = bdiv(new_pool_supply, pool_supply);

        let boo = bdiv(BONE, normalized_weight);
        let token_in_ratio = bpow(pool_ratio, boo);
        let new_token_balance_in = bmul(token_in_ratio, token_balance_in);
        let token_amount_in_after_fee = bsub(new_token_balance_in, token_balance_in);

        let zar = bmul(bsub(BONE, normalized_weight), swap_fee);
        let token_amount_in = bdiv(token_amount_in_after_fee, bsub(BONE, zar));
        token_amount_in
    }

    public fun calc_single_out_given_pool_in(
        token_balance_out: u64,
        token_weight_out: u64,
        pool_supply: u64,
        total_weight: u64,
        pool_amount_in: u64,
        swap_fee: u64
    ): u64 {
        let normalized_weight = bdiv(token_weight_out, total_weight);
        let pool_amount_in_after_exit_fee = bmul(pool_amount_in, bsub(BONE, EXIT_FEE));
        let new_pool_supply = bsub(pool_supply, pool_amount_in_after_exit_fee);
        let pool_ratio = bdiv(new_pool_supply, pool_supply);

        let token_out_ratio = bpow(pool_ratio, bdiv(BONE, normalized_weight));
        let new_token_balance_out = bmul(token_out_ratio, token_balance_out);

        let token_amount_out_before_swap_fee = bsub(token_balance_out, new_token_balance_out);

        let zaz = bmul(bsub(BONE, normalized_weight), swap_fee);
        let token_amount_out = bmul(token_amount_out_before_swap_fee, bsub(BONE, zaz));
        token_amount_out
    }

    public fun calc_pool_in_given_single_out(
        token_balance_out: u64,
        token_weight_out: u64,
        pool_supply: u64,
        total_weight: u64,
        token_amount_out: u64,
        swap_fee: u64
    ): u64 {
        let normalized_weight = bdiv(token_weight_out, total_weight);
        let zoo = bsub(BONE, normalized_weight);
        let zar = bmul(zoo, swap_fee);
        let token_amount_out_before_swap_fee = bdiv(token_amount_out, bsub(BONE, zar));

        let new_token_balance_out = bsub(token_balance_out, token_amount_out_before_swap_fee);
        let token_out_ratio = bdiv(new_token_balance_out, token_balance_out);

        let pool_ratio = bpow(token_out_ratio, normalized_weight);
        let new_pool_supply = bmul(pool_ratio, pool_supply);
        let pool_amount_in_after_exit_fee = bsub(pool_supply, new_pool_supply);

        let pool_amount_in = bdiv(pool_amount_in_after_exit_fee, bsub(BONE, EXIT_FEE));
        pool_amount_in
    }
    
    public fun mul(a: u64, b: u64): u64 {
        bmul(a, b)
    }

    public fun div(a: u64, b: u64): u64 {
        bdiv(a, b)
    }

    // =========================================== Helper Funtion ====================================

    fun btoi(a: u64): u64 {
        a / BONE
    }

    fun bfloor(a: u64): u64 {
        btoi(a) * BONE
    }

    fun badd(a: u64, b: u64): u64 {
        let c = a + b;
        assert!(c >= a, ERR_MATH);
        c
    }

    fun bsub(a: u64, b: u64): u64 {
        let (c, flag) = bsub_sign(a, b);
        assert!(!flag, ERR_MATH);
        c
    }

    fun bsub_sign(a: u64, b: u64): (u64, bool) {
        if (a >= b) {
            (a - b, false)
        } else {
            (b - a, true)
        }
    }

    fun bmul(a: u64, b: u64): u64 {
        // print(&a);
        // print(&b);
        let c0 = a * b;
        // print(&c0);
        assert!(a == 0 || c0 / a == b, ERR_MATH);
        let c1 = c0 + (BONE / 2);
        // print(&c1);
        assert!(c1 >= c0, ERR_MATH);
        let c2 = c1 / BONE;
        // print(&c2);
        let check = string::utf8(b"------");
        // print(&check);
        c2
    }

    fun bdiv(a: u64, b: u64): u64 {
        assert!(b != 0, ERR_MATH);
        let c0 = a * BONE;
        assert!(a == 0 || c0 / a == BONE, ERR_MATH);
        let c1 = c0 + (b / 2);
        assert!(c1 >= c0, ERR_MATH);
        c1 / b
    }

    fun bpowi(a: u64, n: u64): u64 {
        let z:u64 = 0;
        if(n % 2 != 0) {
            z = a;
        } else {
            z = BONE;
        };
        n = n / 2;
        while (n != 0) {
            a = bmul(a, a);
            
            if (n % 2 != 0) {
                z = bmul(z, a);
            };
            n = n / 2;
        };
        z
    }

    fun bpow(base: u64, exp: u64): u64 {
        let whole = bfloor(exp);
        let remain = bsub(exp, whole);
        let whole_pow = bpowi(base, btoi(whole));

        if (remain == 0) {
            whole_pow
        } else {
            let partial_result = bpow_approx(base, remain, BONE);
            bmul(whole_pow, partial_result)
        }
    }

    fun bpow_approx(base: u64, exp: u64, precision: u64): u64 {
        let a = exp;
        let (x, xneg) = bsub_sign(base, BONE);
        let term = BONE;
        let sum = term;
        let negative = false;

        let i = 1;
        while (term >= precision) {
            let big_k = i * BONE;
            let (c, cneg) = bsub_sign(a, bsub(big_k, BONE));
            term = bmul(term, bmul(c, x));
            term = bdiv(term, big_k);

            if (term == 0) {
                break;
            };

            if (xneg) {
                negative = !negative;
            };

            if (cneg) {
                negative = !negative;
            };
            if (negative) {
                sum = bsub(sum, term);
            } else {
                sum = badd(sum, term);
            };

            i = i + 1;
        };
        sum
    }

    // ====================================== Unit Test ===========================================
    // #[test]
    // public fun test_calc_spot_price() {
    //     let spot_price = calc_spot_price(4, 10, 12 , 12, 1000000);
    //     assert!(spot_price == 400400400, ERR_MATH);
    // }

    #[test]
    public fun test_calc_out_given_in() {
        // let k = bpow(1000000, 1000000);
        // print(&k);
        let token_amount_out = calc_out_given_in(100, 50, 60, 50, 10, 1000);
        // print(&token_amount_out);
    }

    #[test]
    public fun test_calc_in_given_out() {
        // let k = bpow(1000000, 1000000);
        // print(&k);
        let token_amount_in = calc_in_given_out(100, 50, 60, 50, 10, 1000);
        // print(&token_amount_in);
    }

    // #[test]
    // public fun test_calc_pool_out_given_single_in() {
    //     let pool_amo
    // }
}