// script {    
//     use std::string;
//     use std::debug::print;
//     use lst_deployed_addr::Liquid_Staking_Token;
//     fun get_fa_address() {
//         let name = string::utf8(b"Staked APT");
//         let symbol = string::utf8(b"stAPT");
//         let fa_address = Liquid_Staking_Token::get_token_address(name, symbol);
//         print(&fa_address);
//     }
// }