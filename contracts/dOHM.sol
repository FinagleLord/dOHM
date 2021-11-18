// SPDX-License-Identifier: WTFPL
pragma solidity >=0.8.0;

import "./interfaces/IwOHM.sol";
import "./interfaces/IStaking.sol";

import "./types/LowGasERC20.sol";

// consumers - take out a loan that pays itself off
// lps - lend out wOHM to earn interest
contract DegenOHM is ERC20("Degen OHM", "dOHM", 18) {

    /////////////////////// Events ///////////////////////

    event LiquidityProvided(uint256 indexed amountIn, uint256 indexed amountOut);
    event LiquidityRemoved(uint256 indexed amountIn, uint256 indexed amountOut);
    event Deposit(uint256 indexed lockupAmount, uint256 indexed payoutAmount);
    event Withdraw(uint256 indexed lockupAmount);


    /////////////////////// Structs ///////////////////////

    struct Receipt {
        uint256 lockupAmount;               // amount locked, and owed to depositor
        uint256 depositIndex;               // index user deposited
        uint256 releaseIndex;               // deposit index
        bool paid;                          // if user has withdrawn funds or not
    }

    mapping( address => Receipt[] ) public loanReceipts;

    ///////////////////////  Constants  ///////////////////////

    ERC20 public immutable sOHM;            // toke sold at a discount.

    ERC20 public immutable wOHM;            // token deposited/earned by LPs.

    IStaking public immutable staking;      // Staking contract

    uint256 public constant DIVISOR = 1e9;  // 1,000,000,000


    ///////////////////////  Storage  ///////////////////////  

    uint256 public maxRebases = 36;         // 10 days of rebases - maximum number of rebases a user can use as principal for a loan.

    uint256 public RFV_CV = 333_000_000;    // 33.3 % - risk free value control variable.
    
    uint256 public totalDebt;               // total amount of sOHM owed back to interest sellers.

    address public policy;                  // regularly updates RFV, until governance can take over.
    
    bool public paused;                     // if lockup and lp deposits are paused.


    ///////////////////////  Modifiers  ///////////////////////

    modifier onlyPolicy() {
        require(msg.sender == policy);
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }


    ///////////////////////  Init  ///////////////////////

    constructor(
        ERC20 _sOHM, 
        ERC20 _wOHM, 
        IStaking _staking,
        address _policy,
        uint256 _maxRebases
    ) {
        sOHM = _sOHM;
        wOHM = _wOHM;
        staking = _staking;
        policy = _policy;
        maxRebases = _maxRebases;
    }


    ///////////////////////  Policy  ///////////////////////

    // set risk free value, policy only
    // RFV is the value LPs are willing to pay out for future interest
    function set_RFV(
        uint256 newRFV
    ) external onlyPolicy {
        require(newRFV <= DIVISOR);
        RFV_CV = newRFV;
    }

    function set_maxRebases(
        uint256 newMaxRebases
    ) external onlyPolicy {
        maxRebases = newMaxRebases;
    }

    function set_policy(
        address newPolicy
    ) external onlyPolicy {
        policy = newPolicy;
    }
    
    function set_paused(
        bool isPaused
    ) external onlyPolicy {
        paused = isPaused;
    }
    

    /////////////////////// Public ///////////////////////

    /*
     *  Sell the next 5 days of sOHM interest to the pool at a discount.
     *  @param to reciepient of payout.
     *  @param lockupAmount amount to be locked.
     *  @param epochs amount of rebases to sell to the pool
     */
    function takeLoan(
        address to,
        uint256 lockupAmount,
        uint256 epochs
    ) external whenNotPaused {
        require(epochs <= maxRebases, "INPUT");
        accrue();
        // interface users receipts
        Receipt[] storage receipts = loanReceipts[ msg.sender ];
        // interface next available index
        Receipt storage receipt = receipts[ receipts.length ];
        // pull users tokens
        sOHM.transferFrom(msg.sender, address(this), lockupAmount);
        
        // log lockup amount on receipt
        receipt.lockupAmount = lockupAmount;
        // log deposit index on receipt
        receipt.depositIndex = staking.epoch().number;
        // log release index on receipt
        receipt.releaseIndex = staking.epoch().number + epochs;

        // increase total debt
        totalDebt += lockupAmount;
        // determine payout amount
        uint256 payoutAmount = lockupAmount * RFV_CV / DIVISOR;
        // transfer payout
        emit Deposit(lockupAmount, payoutAmount);
        wOHM.transfer( to, IwOHM( address( wOHM ) ).wOHMValue( payoutAmount ) );
    }

    // withdraw deposited sOHM after vesting is complete
    function claimCollateral(
        uint256 receiptID,
        address to
    ) external {
        // interface users receipts
        Receipt[] storage receipts = loanReceipts[ msg.sender ];
        // interface specific receipt
        Receipt storage receipt = receipts[ receiptID ];
        // make sure the receipt hasn't already been paid
        require(receipt.paid == false, "PAID");
        // make sure the receipts fully vested
        require(receipt.depositIndex <= receipt.releaseIndex, "NOT VESTED");
        // set it as paid
        receipt.paid = true;
        // decrease debt
        totalDebt -= receipt.lockupAmount;
        // return deposited funds
        emit Withdraw(receipt.lockupAmount);
        sOHM.transfer(to, receipt.lockupAmount);
    }
    
    // provide your wOHM and receive LP tokens
    function provideLiquidity(
        address to, 
        uint256 amount
    ) external whenNotPaused returns (uint256) {
        accrue();
        wOHM.transferFrom(msg.sender, address( this ), amount);        
        uint256 mintAmount = provideLiquidityAmountOut( amount );
        emit LiquidityProvided(amount, mintAmount);
        _mint( to,  mintAmount);
        return mintAmount;
    }
    
    // redeem LP tokens for wOHM
    function removeLiquidity(
        address to, 
        uint256 amount
    ) external returns (uint256) {
        accrue();
        require( balanceOf[ msg.sender ] >= amount, "AMOUNT");
        uint256 refundAmount = removeLiquidityAmountOut( amount );
        emit LiquidityRemoved (amount, refundAmount);
        _burn( msg.sender,  amount);
        wOHM.transfer(to, refundAmount );
        return refundAmount;
    }
    
    // convert earned sOHM to wOHm so it can be claimed by LPs
    function accrue() public returns (uint256) {
        if ( pendingAccrual() > 0 ) {
            return IwOHM( address( wOHM ) ).wrapFromsOHM( pendingAccrual() );
        } else {
            return 0;
        }
    }
    
    ///////////////////////  View  ///////////////////////

    // amount of sOHM that can currently be accrued
    function pendingAccrual() public view returns (uint256) {
        if ( sOHM.balanceOf( address( this ) ) > totalDebt ) {
            return sOHM.balanceOf( address( this ) ) - totalDebt;
        } else {
            return 0;
        }
    }
    
    // calculate amount of LP tokens that should be minted for a deposit amount of wOHM
    function provideLiquidityAmountOut(
        uint256 amountIn
    ) public view returns (uint256) {
        if ( totalSupply == 0 ) return amountIn;

        return amountIn * wOHM.balanceOf( address( this ) ) / totalSupply;
    }
    
    // calculate amount of wOHM that LP tokens can be redeemed for
    function removeLiquidityAmountOut(
        uint256 amountIn
    ) public view returns (uint256) {
        if ( totalSupply == 0 ) return amountIn;
        
        return amountIn * totalSupply / wOHM.balanceOf( address( this ) );
    }
}
