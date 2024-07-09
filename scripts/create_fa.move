// script {    
//     use std::string;
//     use lst_deployed_addr::Liquid_Staking_Token;
//     fun create_fa(sender: &signer) {
//         let name = string::utf8(b"Staked APT");
//         let symbol = string::utf8(b"stAPT");
//         let uri = string::utf8(b"http://example.com/favicon.ico");
//         let project = string::utf8(b"http://example.com");
//         lst_deployed_addr::Liquid_Staking_Token::create_fa(
//             name,
//             symbol,
//             6,
//             uri,
//             project,
//         );
//     }
// }