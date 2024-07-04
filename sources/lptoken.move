// module lptoken_addr::LP_Token {
//     struct LPToken {}
//     fun init_module(sender: &signer) {
//         aptos_framework::managed_coin::initialize<LPToken>(
//             sender,
//             b"LP Token",
//             b"LPT",
//             6,
//             false,
//         );
//     }
// }