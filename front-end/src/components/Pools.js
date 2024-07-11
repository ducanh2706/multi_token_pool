import React, {useState} from "react"

import Table from '@mui/material/Table';
import TableBody from '@mui/material/TableBody';
import TableCell from '@mui/material/TableCell';
import TableContainer from '@mui/material/TableContainer';
import TableHead from '@mui/material/TableHead';
import TableRow from '@mui/material/TableRow';
import Paper from '@mui/material/Paper';
import AddIcon from '@mui/icons-material/Add';
import { Input, Popover, Radio, Modal, message } from "antd";
import tokenList from "../tokenList.json";
import KeyboardArrowDownIcon from '@mui/icons-material/KeyboardArrowDown';
import RemoveIcon from '@mui/icons-material/Remove';


function Pools(){
    const pools = [
        {
            assets: [
                {
                    asset: tokenList[0],
                    weight: 50,
                },
                {
                    asset: tokenList[1],
                    weight: 50,
                },
            ],
        },
        {
            assets: [
                {
                    asset: tokenList[2],
                    weight: 60,
                },
                {
                    asset: tokenList[3],
                    weight: 20,
                },
                {
                    asset: tokenList[4],
                    weight: 20,
                },
            ],
        },
        {
            assets: [
                {
                    asset: tokenList[5],
                    weight: 40,
                },
                {
                    asset: tokenList[7],
                    weight: 60,
                },
            ],
        }
    ];

    const [pool, setPool] = useState(pools[0]);
    const [isOpenDeposit, setIsOpenDeposit] = useState(false);
    const [isOpenWithdraw, setIsOpenWithdraw] = useState(false);

    function openDeposit(pool){
        console.log(pool);
        setPool(pool);
        setIsOpenDeposit(true);   
    }

    function openWithdraw(pool){
        setPool(pool);
        setIsOpenWithdraw(true);
    }

    return (
        <div>
            <Modal
                open={isOpenDeposit}
                footer={null}
                onCancel={() => setIsOpenDeposit(false)}
                title="Add liquidity"
            >
                <div className="modalContent" style={{paddingTop: 20}}>
                    {pool.assets.map((asset, index) => (
                        <div className="inputsDeposit">
                            <Input
                                className="depositInput"
                                placeholder="0"
                            />
                            <div className="depositAsset">
                                <img src={asset.asset.img} alt="assetOneLogo" className="assetLogo" />
                                {asset.asset.ticker}
                            </div>
                        </div>
                    ))}
                    <div style={{width: "90%", margin: "0 auto"}}>
                        <div className="swapButton" style={{marginBottom: 0}}>Add liquidity</div>
                    </div>
                </div>
                
            </Modal>

            <Modal
                open={isOpenWithdraw}
                footer={null}
                onCancel={() => setIsOpenWithdraw(false)}
                title="Withdraw"
            >
                <div className="modalContent">
                hallo
                </div>
            </Modal>

            <div className="poolsBox">
                <div className="poolBoxHeader">
                    <h2>Pools</h2>
                </div>
                <TableContainer component={Paper}>
                    <Table aria-label="simple table">
                        <TableHead>
                        <TableRow >
                            <TableCell sx={{maxWidth: 200}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} >Asset</TableCell>
                            <TableCell sx={{maxWidth: 50}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">Pool Value</TableCell>
                            <TableCell sx={{maxWidth: 50}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">Your position</TableCell>
                            <TableCell sx={{maxWidth: 40}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">Volume (24h)</TableCell>
                            <TableCell sx={{maxWidth: 25}}  style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">APR</TableCell>
                            <TableCell sx={{maxWidth: 30}}  style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right"></TableCell>
                        </TableRow>
                        </TableHead>
                        <TableBody>
                        {pools.map((pool, index) => (
                            <TableRow
                            sx={{ '&:last-child td, &:last-child th': { border: 0 } }}
                            >
                                <TableCell sx={{maxWidth: 150}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">
                                    <div className="assetBox">
                                        {
                                            pool.assets.map((asset, index) => (
                                                
                                                <div style={{display: 'inline-block'}} className="assetHihi">
                                                        <div className="asset">
                                                            <img src={asset.asset.img} alt="assetOneLogo" className="assetLogo"/>
                                                            {asset.asset.ticker}
                                                            <span style={{fontSize: 14, color: "#d3d3d3"}}>
                                                                {asset.weight}%
                                                            </span>
                                                        </div>
                                                </div>
                                            ))
                                        }
                                    </div>
                                </TableCell>
                                <TableCell style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">
                                    10.00
                                </TableCell>
                                <TableCell style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">
                                    10.00
                                </TableCell>
                                <TableCell sx={{maxWidth: 40}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">
                                    10.00
                                </TableCell>
                                <TableCell sx={{maxWidth: 25}} style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">
                                    10.00
                                </TableCell>
                                <TableCell sx={{maxWidth: 30}}  style={{fontSize: 16, color: 'white', fontWeight: 'bold', background: '#0E111B'}} align="right">
                                    <div style={{display: 'inline-block'}}>
                                        <div className="colContainer">
                                            <div className="generalButton" onClick={() => openDeposit(pool)}> <AddIcon/></div>
                                            <div className="generalButton" onClick={() => openWithdraw(pool)}> <RemoveIcon/></div>
                                        </div>
                                    </div>
                                </TableCell>
                            </TableRow>
                            
                        ))}
                        </TableBody>
                    </Table>
                </TableContainer>
            </div>
        </div>
    )
}

export default Pools;