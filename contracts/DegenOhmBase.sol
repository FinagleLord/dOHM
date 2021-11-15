// SPDX-License-Identifier: WTFPL
pragma solidity >=0.8.0;

abstract contract ERC20 {
    /*///////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /*///////////////////////////////////////////////////////////////
                             METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;

    string public symbol;

    uint8 public immutable decimals;

    /*///////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    /*///////////////////////////////////////////////////////////////
                              ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;

        // This is safe because the sum of all user
        // balances can't exceed type(uint256).max!
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }

        balanceOf[from] -= amount;

        // This is safe because the sum of all user
        // balances can't exceed type(uint256).max!
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /*///////////////////////////////////////////////////////////////
                       INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 amount) internal virtual {
        totalSupply += amount;

        // This is safe because the sum of all user
        // balances can't exceed type(uint256).max!
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        balanceOf[from] -= amount;

        // This is safe because a user won't ever
        // have a balance larger than totalSupply!
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}

interface IwOHM {
    function wrapFromsOHM( uint256 _amount ) external returns (uint256);
    function wOHMValue( uint256 _amount ) external view returns (uint256);
}

contract DegenOHM is ERC20("Degen OHM", "dOHM", 18) {

    /////////////////////// Events ///////////////////////

    event LiquidityProvided(uint256 indexed amountIn, uint256 indexed amountOut);
    
    event LiquidityRemoved(uint256 indexed amountIn, uint256 indexed amountOut);
    
    event Deposit(uint256 indexed lockupAmount, uint256 indexed payoutAmount);
   
    event Withdraw(uint256 indexed lockupAmount);


    /////////////////////// Structs ///////////////////////

    struct Receipt {
        uint256 lockupAmount;               // amount locked, and owed to depositor
        uint256 releaseTimestamp;           // creation time + 5 days
        bool paid;                          // if user has withdrawn funds or not
    }


    ///////////////////////  State  ///////////////////////

    ERC20 public sOHM;                      // toke sold at a discount.

    ERC20 public wOHM;                      // token deposited/earned by LPs.

    address public policy = msg.sender;     // regularly updates RFV, until governance can take over.
    
    address public feeTo = msg.sender;      // receives fees if any.
    
    uint256 public constant DIVISOR = 1e6;  // 1,000,000
    
    uint256 public RFV_BIPS = 300_000;      // 3.0 %
    
    uint256 public depositFee_BIPS = 8_000; // 0.08 %
    
    uint256 public mintFee_BIPS = 4_000;    // 0.04 %
    
    uint256 public totalDebt;               // total amount of sOHM owed back to interest sellers.
    
    bool public depositFee_active = true;   // if true, depositFee_BIPS is taken when selling interest.
    
    bool public mintFee_active = true;      // if true, mintFee_BIPS is taken when depositing liquidity.
    
    bool public paused;                     // if lockup and lp deposits are paused.
    
    mapping( address => Receipt[] ) public sellerReceipts;  

    ///////////////////////  Only Policy  ///////////////////////

    modifier onlyPolicy() {
        require(msg.sender == policy);
        _;
    }
    
    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }


    ///////////////////////  Policy  ///////////////////////

    constructor(ERC20 _sOHM, ERC20 _wOHM) {
        sOHM = _sOHM;
        wOHM = _wOHM;
    }

    ///////////////////////  Policy  ///////////////////////

    // set risk free value, policy only
    // RFV is the value LPs are willing to pay out for future interest
    function set_RFV(
        uint256 newRFV
    ) external onlyPolicy {
        require(newRFV <= DIVISOR);
        RFV_BIPS = newRFV;
    }

    function set_policy(
        address newPolicy
    ) external onlyPolicy {
        policy = newPolicy;
    }
    
    function set_feeTo(
        address newFeeTo
    ) external onlyPolicy {
        feeTo = newFeeTo;
    }
    
    function set_depositFee_active(
        bool active
    ) external onlyPolicy {
        depositFee_active = active;
    }
    
    function set_mintFee_active(
        bool active
    ) external onlyPolicy {
        mintFee_active = active;
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
     */
    function deposit(
        address to,
        uint256 lockupAmount
    ) external whenNotPaused {
        accrue();
        // interface users receipts
        Receipt[] storage receipts = sellerReceipts[ msg.sender ];
        // interface next available index
        Receipt storage receipt = receipts[ receipts.length ];
        // pull users tokens
        sOHM.transferFrom(msg.sender, address(this), lockupAmount);
        
        if (depositFee_active) {
            // calculate fee amount
            uint256 feeAmount = lockupAmount * depositFee_BIPS / DIVISOR;
            // transfer policy fee
            sOHM.transfer(feeTo, feeAmount);
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
        uint256 payoutAmount = lockupAmount * RFV_BIPS / DIVISOR;
        // transfer payout
        emit Deposit(lockupAmount, payoutAmount);
        wOHM.transfer( to, IwOHM( address( wOHM ) ).wOHMValue( payoutAmount ) );
    }

    // withdraw deposited sOHM after vesting is complete
    function withdraw(
        uint256 receiptID,
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
    function provideLiquidity(
        address to, 
        uint256 amount
    ) external whenNotPaused returns (uint256) {
        accrue();
        wOHM.transferFrom(msg.sender, address( this ), amount);
        
        if (mintFee_active) {
            // calculate fee amount
            uint256 feeAmount = amount * mintFee_BIPS / DIVISOR;
            // transfer policy fee
            wOHM.transfer(feeTo, feeAmount);
            // adjust lockup fee to account for fee
            amount -= feeAmount;
        }
        
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
        require( balanceOf[ msg.sender ] >= amount, "!amount");
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
