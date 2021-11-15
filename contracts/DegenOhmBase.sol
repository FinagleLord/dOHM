// SPDX-License-Identifier: WTFPL
pragma solidity =0.8.9;

// Rari Capital low gas ERC20
import "https://github.com/Rari-Capital/solmate/blob/38b518cf7a66868111bac15f99559108b1e12dba/src/erc20/ERC20.sol";

interface IwOHM {
    function wrapFromsOHM( uint _amount ) external returns ( uint );
    function wOHMValue( uint _amount ) external view returns ( uint );
}

contract DegenOHM is ERC20("Degen OHM", "dOHM", 18) {

    /////////////////////// Events ///////////////////////

    event LiquidityProvided(uint indexed amountIn, uint indexed amountOut);
    
    event LiquidityRemoved(uint indexed amountIn, uint indexed amountOut);
    
    event Deposit(uint indexed lockupAmount, uint indexed payoutAmount);
   
    event Withdraw(uint indexed lockupAmount);


    /////////////////////// Structs ///////////////////////

    struct Receipt {
        uint lockupAmount;              // amount locked, and owed to depositor
        uint releaseTimestamp;          // creation time + 5 days
        bool paid;                      // if user has withdrawn funds or not
    }


    ///////////////////////  State  ///////////////////////

    address public admin;                   // regularly updates RFV, until governance can take over.
    
    ERC20 public sOHM;                      // toke sold at a discount.

    ERC20 public wOHM;                      // token deposited/earned by LPs.
    
    uint public totalDebt;                  // total amount of sOHM owed back to interest sellers.
    
    uint public constant DIVISOR = 1e5;     // 100,000
    
    uint public RFV_BIPS = 30_000;          // 3.0 %
    
    uint public depositFee_BIPS = 800;      // 0.08 %
    
    uint public mintFee_BIPS = 400;         // 0.04 %
    
    bool public depositFee_active = true;   // if true, depositFee_BIPS is taken when selling interest.
    
    bool public mintFee_active = true;      // if true, mintFee_BIPS is taken when depositing liquidity.
    
    mapping( address => Receipt[] ) public sellerReceipts;  


    ///////////////////////  Policy  ///////////////////////

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
    
    function set_depositFee_active(
        bool active
    ) external {
        require(msg.sender == admin);
        depositFee_active = active;
    }
    
    function set_mintFee_active(
        bool active
    ) external {
        require(msg.sender == admin);
        mintFee_active = active;
    }

    // TODO add pausable

    /////////////////////// Public ///////////////////////

    /*
     *  Sell the next 5 days of sOHM interest to the pool at a discount.
     *  @param to reciepient of payout.
     *  @param lockupAmount amount to be locked.
     */
    function deposit(
        address to,
        uint lockupAmount
    ) external {
        accrue();
        // interface users receipts
        Receipt[] storage receipts = sellerReceipts[ msg.sender ];
        // interface next available index
        Receipt storage receipt = receipts[ receipts.length ];
        // pull users tokens
        sOHM.transferFrom(msg.sender, address(this), lockupAmount);
        
        if (depositFee_active) {
            // calculate fee amount
            uint feeAmount = lockupAmount * depositFee_BIPS / DIVISOR;
            // transfer admin fee
            sOHM.transfer(admin, feeAmount);
            // adjust lockup fee to account for fee
            lockupAmount -= feeAmount;
        }
        
        // log lockup amount on receipt
        receipt.lockupAmount = lockupAmount;
        // log release time on receipt
        receipt.releaseTimestamp = block.timestamp + 5 days;
        // increase total debt
        totalDebt += lockupAmount;
        // determine payout amount
        uint payoutAmount = lockupAmount * RFV_BIPS / DIVISOR;
        // transfer payout
        emit Deposit(lockupAmount, payoutAmount);
        wOHM.transfer( to, IwOHM( address( wOHM ) ).wOHMValue( payoutAmount ) );
    }

    // withdraw deposited sOHM after vesting is complete
    function withdraw(
        uint receiptID,
        address to
    ) external {
        // interface users receipts
        Receipt[] storage receipts = sellerReceipts[ msg.sender ];
        // interface specific receipt
        Receipt storage receipt = receipts[ receiptID ];
        // make sure the receipt hasn't already been paid
        require(receipt.paid == false, "already paid");
        // make sure the receipts fully vested
        require(receipt.releaseTimestamp <= block.timestamp, "not fully vested");
        // set it as paid
        receipt.paid = true;
        // decrease debt
        totalDebt -= receipt.lockupAmount;
        // return deposited funds
        emit Withdraw(receipt.lockupAmount);
        sOHM.transfer(to, receipt.lockupAmount);

    }
    
    // provide your wOHM and receive LP tokens
    function provideLiquidity(address to, uint amount) external returns ( uint ) {
        accrue();
        wOHM.transferFrom(msg.sender, address( this ), amount);
        
        if (mintFee_active) {
            // calculate fee amount
            uint feeAmount = amount * mintFee_BIPS / DIVISOR;
            // transfer admin fee
            wOHM.transfer(admin, feeAmount);
            // adjust lockup fee to account for fee
            amount -= feeAmount;
        }
        
        uint mintAmount = provideLiquidityAmountOut( amount );
        emit LiquidityProvided(amount, mintAmount);
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
        emit LiquidityRemoved (amount, refundAmount);
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
    
    ///////////////////////  View  ///////////////////////

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
}
