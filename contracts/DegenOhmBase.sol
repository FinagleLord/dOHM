// SPDX-License-Identifier: WTFPL
pragma solidity =0.8.9;

import "https://github.com/Rari-Capital/solmate/blob/38b518cf7a66868111bac15f99559108b1e12dba/src/erc20/ERC20.sol";

interface IwOHM {
    function wrapFromsOHM( uint _amount ) external returns ( uint );
    function sOHMValue( uint _amount ) external view returns ( uint );
    function wOHMValue( uint _amount ) external view returns ( uint );
}

contract DegenOHM is ERC20("Low Risk Degen OHM", "LR-DOHM", 18) {
    
    struct Receipt {
        uint lockupAmount;     // amount locked, and owed to depositor
        uint releaseTimestamp; // creation time + 5 days
    }
    
    address public admin;
    
    ERC20 public sOHM;
    ERC20 public wOHM;
    
    uint public totalDebt;
    
    uint public RFV_BIPS = 3000; // 3.0 %
    uint public constant DIVISOR = 1e4; // 10,000
    
    mapping( address => Receipt[] ) public sellerReceipts;
    mapping( uint => mapping ( address => uint ) ) public userShares;
    
    // lockup sOHM for 5 days, subsequently selling your accrued 
    // interest at a discount, with the benefit of immediiate payout
    function lock(
        address to,
        uint lockupAmount,
        uint pid 
    ) external {
        accrue();
        require(pid <= 3, "!pid" );
        // interface users receipts
        Receipt[] storage receipts = sellerReceipts[ msg.sender ];
        // interface next available index
        Receipt storage receipt = receipts[ receipts.length ];
        // pull users tokens
        sOHM.transferFrom(msg.sender, address(this), lockupAmount);
        // log lockup amount on receipt
        receipt.lockupAmount = lockupAmount;
        // log release time on receipt
        receipt.releaseTimestamp = block.timestamp + 5 days;
        // increase total debt
        totalDebt += lockupAmount;
        // determine payout amount
        uint payoutAmount = lockupAmount * RFV_BIPS / DIVISOR;
        // transfer payout
        wOHM.transfer( to, IwOHM( address( wOHM ) ).wOHMValue( payoutAmount ) );
    }
    
    // provide your wOHM and receive LP tokens
    function provideLiquidity(address to, uint amount) external returns ( uint ) {
        accrue();
        wOHM.transferFrom(msg.sender, address( this ), amount);
        uint mintAmount = provideLiquidityAmountOut( amount );
        _mint( to,  mintAmount);
        return mintAmount;
    }
    
    // redeem LP tokens for wOHM
    function removeLiquidity(
        address to, 
        uint amount
    ) external returns ( uint ) {
        accrue();
        require( balanceOf[ msg.sender ] >= amount, "!amount");
        uint refundAmount = removeLiquidityAmountOut( amount );
        _burn( msg.sender,  amount);
        wOHM.transfer(to, refundAmount );
        return refundAmount;
    }
    
    // convert earned sOHM to wOHm so it can be claimed by LPs
    function accrue() public returns ( uint ) {
        if ( pendingAccrual() > 0 ) {
            return IwOHM( address( wOHM ) ).wrapFromsOHM( pendingAccrual() );
        } else {
            return 0;
        }
    }
    
    // amount of sOHM that can currently be accrued
    function pendingAccrual() public view returns ( uint ) {
        if ( sOHM.balanceOf( address( this ) ) > totalDebt ) {
            return sOHM.balanceOf( address( this ) ) - totalDebt;
        } else {
            return 0;
        }
    }
    
    // calculate amount of LP tokens that should be minted for a deposit amount of wOHM
    function provideLiquidityAmountOut(
        uint amountIn
    ) public view returns ( uint ) {
        if ( totalSupply == 0 ) return amountIn;
        return amountIn * wOHM.balanceOf( address( this ) ) / totalSupply;
    }
    
    // calculate amount of wOHM that LP tokens can be redeemed for
    function removeLiquidityAmountOut(
        uint amountIn
    ) public view returns ( uint ) {
        if ( totalSupply == 0 ) return amountIn;
        return amountIn * totalSupply / wOHM.balanceOf( address( this ) );
    }
    
    // set admin, admin only
    function set_Admin(
        address newAdmin
    ) external {
        require(msg.sender == admin);
        admin = newAdmin;
    }
    
    // set risk free value, admin only
    function set_RFV(
        uint newRFV
    ) external {
        require(msg.sender == admin);
        require(newRFV <= DIVISOR);
        RFV_BIPS = newRFV;
    }
}
