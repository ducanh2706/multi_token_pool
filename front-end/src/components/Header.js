import React from "react";
import Logo from "../moralis-logo.svg";
import Eth from "../eth.svg";
import { Link } from "react-router-dom";
import { WalletSelector } from "@aptos-labs/wallet-adapter-ant-design";
import "@aptos-labs/wallet-adapter-ant-design/dist/index.css";

function Header(props) {

  const {address, isConnected, connect} = props;

  return (
    <header>
      <div className="leftH">
        <img src={Logo} alt="logo" className="logo" />
        <Link to="/" className="link">
          <div className="headerItem">Swap</div>
        </Link>
        <Link to="/create" className="link">
          <div className="headerItem">Create Pool</div>
        </Link>
        <Link to="/pools" className="link">
          <div className="headerItem">Pools</div>
        </Link>
      </div>
      <div className="rightH">
      <WalletSelector />
      </div>
    </header>
  );
}

export default Header;
