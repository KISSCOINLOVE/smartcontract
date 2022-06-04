// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./RewardTokenDividendTracker.sol";
import "../Libraries/SafeMath.sol";
import "../Libraries/IterableMapping.sol";
import "../Interfaces/IDex.sol";

contract RewardToken is ERC20Upgradeable, OwnableUpgradeable {
    using Address for address payable;

    IRouter public router;
    address public  pair;

    string public rewardTokenName;
    uint8 _decimals;

    bool private swapping;
    bool public swapEnabled = true;

    RewardTokenDividendTracker public dividendTracker;

    address public constant deadWallet = 0x000000000000000000000000000000000000dEaD;
    address public rewardToken;
    address public marketingWallet;
    
    uint256 public swapTokensAtAmount;
    uint256 public maxWalletBalance;
    uint256 public maxTxAmount;
    
            ///////////////
           //   Fees    //
          ///////////////
          
    uint256 public rewardsTax;
    uint256 public liquidityTax;
    uint256 public marketingTax;
    uint256 public totalTaxes;

    uint256 public extraSellTax;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing;
    
         ////////////////
        //  Anti Bot  //
       ////////////////
       
    mapping (address => bool) private _isBot;
       
    mapping (address => bool) private _isExcludedFromFees;
    mapping (address => bool) public automatedMarketMakerPairs;
    
        ///////////////
       //   Events  //
      ///////////////
      
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event SendDividends(uint256 tokensSwapped,uint256 amount);
    event ProcessedDividendTracker(uint256 iterations,uint256 claims,uint256 lastProcessedIndex,bool indexed automatic,uint256 gas,address indexed processor);
    

    function initialize(
        address owner_, 
        string memory name_, 
        string memory symbol_, 
        uint8 decimals_, 
        uint256 totalSupply_,
        address[4] memory addresses, // 0: router, 1: marketingWallet, 2: rewardToken, 3: dividendTrackerImplementation
        uint256[3] memory _taxes, // 0: rewards, 1: liquidity, 2: marketing
        uint256[4] memory _limitsAndThresholds // 0: swapTokensAtAmount, 1: maxTxAmount , 2: maxWalletBalance, 3: minimumTokenBalanceForDividends
        )external initializer returns(bool){
        __ERC20_init(name_, symbol_);
        __Ownable_init();
        _decimals = decimals_;
        rewardToken = addresses[2];
        rewardTokenName = IERC20Metadata(addresses[2]).name();
        rewardsTax = _taxes[0];
        liquidityTax = _taxes[1];
        marketingTax = _taxes[2];
        totalTaxes = rewardsTax + marketingTax + liquidityTax;
        swapTokensAtAmount = _limitsAndThresholds[0];
        maxTxAmount = _limitsAndThresholds[1];
        maxWalletBalance = _limitsAndThresholds[2];

        gasForProcessing = 300000;

    	dividendTracker = RewardTokenDividendTracker(Clones.clone(addresses[3]));
        dividendTracker.initialize(rewardToken, _limitsAndThresholds[3]);
    	marketingWallet = addresses[1];

    	router = IRouter(addresses[0]);
         // Create a  pair for this new token
        pair = IFactory(router.factory()).createPair(address(this), router.WETH());

        _setAutomatedMarketMakerPair(pair, true);


        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker), true);
        dividendTracker.excludeFromDividends(address(this), true);
        dividendTracker.excludeFromDividends(owner(), true);
        dividendTracker.excludeFromDividends(deadWallet, true);
        dividendTracker.excludeFromDividends(address(router), true);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(marketingWallet, true);
        
        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner_, totalSupply_);
        transferOwnership(owner_);
        return true;
    }

    receive() external payable {}

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function processDividendTracker(uint256 gas) external {
		(uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }
    
    /// @notice Manual claim the dividends after claimWait is passed
    ///    This can be useful during low volume days.
    function claim() external {
		dividendTracker.processAccount(msg.sender, false);
    }
    
    /// @notice Withdraw tokens sent by mistake.
    /// @param tokenAddress The address of the token to withdraw
    function rescueBEP20Tokens(address tokenAddress) external onlyOwner{
        IERC20(tokenAddress).transfer(msg.sender, IERC20(tokenAddress).balanceOf(address(this)));
    }
    
    /// @notice Send remaining BNB to marketingWallet
    /// @dev It will send all BNB to marketingWallet
    function forceSend() external {
        uint256 BNBbalance = address(this).balance;
        payable(marketingWallet).sendValue(BNBbalance);
    }
    
    
     /////////////////////////////////
    // Exclude / Include functions //
   /////////////////////////////////

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "RewardToken: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }
        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    /// @dev "true" to exlcude, "false" to include
    function excludeFromDividends(address account, bool value) external onlyOwner{
	    dividendTracker.excludeFromDividends(account, value);
	}


     ///////////////////////
    //  Setter Functions //
   ///////////////////////


    /// @dev Update marketingWallet address. It must be different
    ///   from the current one
    function setmarketingWallet(address newmarketingWallet) external onlyOwner{
        require(marketingWallet != newmarketingWallet, "marketingWallet already set");
        marketingWallet = newmarketingWallet;
    }

    function setMaxWalletBalance(uint256 amount) external onlyOwner{
        require(amount >= totalSupply() * 1 / 100, "Max wallet balance must be >= 0.01% of total supply");
        maxWalletBalance = amount;
    }

    function setMaxTxAmount(uint256 amount) external onlyOwner{
        require(amount >= totalSupply() * 5 / 1000, "Max tx amount must be >= 0.05% of total supply");
        maxTxAmount = amount;
    }

    /// @notice Update the threshold to swap tokens for liquidity,
    ///   marketing and dividends.
    function setSwapTokensAtAmount(uint256 amount) external onlyOwner{
        swapTokensAtAmount = amount;
    }

    /// @notice Update taxes and totalTaxes
    /// @dev  Total fees must be less or equal to 40%.
    function setTaxes(uint256 _rewards, uint256 _liquidity, uint256 _marketing, uint256 _extraSell) external onlyOwner{
        require(_rewards + _liquidity + _marketing + _extraSell <= 400, "Total fees must be <= 40%");
        rewardsTax = _rewards;
        liquidityTax = _liquidity;
        marketingTax = _marketing;
        extraSellTax = _extraSell;
        totalTaxes = rewardsTax + liquidityTax + marketingTax;
    }

    /// @notice Enable or disable internal swaps
    /// @dev Set "true" to enable internal swaps for liquidity, marketing and dividends
    function setSwapEnabled(bool _enabled) external onlyOwner{
        swapEnabled = _enabled;
    }

    /// @param bot The bot address
    /// @param value "true" to blacklist, "false" to unblacklist
    function setBot(address bot, bool value) external onlyOwner{
        require(_isBot[bot] != value);
        _isBot[bot] = value;
    }

    /// @dev Set new pairs created due to listing in new DEX
    function setAutomatedMarketMakerPair(address newPair, bool value) external onlyOwner {
        _setAutomatedMarketMakerPair(newPair, value);
    }

    function _setAutomatedMarketMakerPair(address newPair, bool value) private {
        require(automatedMarketMakerPairs[newPair] != value, "RewardToken: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[newPair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(newPair, true);
        }

        emit SetAutomatedMarketMakerPair(newPair, value);
    }

    /// @notice Update the gasForProcessing needed to auto-distribute rewards
    /// @param newValue The new amount of gas needed
    /// @dev The amount should not be greater than 500k to avoid expensive transactions
    function setGasForProcessing(uint256 newValue) external onlyOwner {
        require(newValue >= 200000 && newValue <= 500000, "RewardToken: gasForProcessing must be between 200,000 and 500,000");
        require(newValue != gasForProcessing, "RewardToken: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    /// @dev Update the dividendTracker claimWait
    function setClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

     //////////////////////
    // Getter Functions //
   //////////////////////

    function getClaimWait() external view returns(uint256) {
        return dividendTracker.claimWait();
    }


    function isBot(address _bot) external view returns(bool){
        return _isBot[_bot];
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
    	return dividendTracker.withdrawableDividendOf(account);
  	}

  	function dividendTokenBalanceOf(address account) public view returns (uint256) {
  		return dividendTracker.balanceOf(account);
  	}

    function getAccountDividendsInfo(address account)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
        return dividendTracker.getAccount(account);
    }

	function getAccountDividendsInfoAtIndex(uint256 index)
        external view returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256) {
    	return dividendTracker.getAccountAtIndex(index);
    }

    function getLastProcessedIndex() external view returns(uint256) {
    	return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

     ////////////////////////
    // Transfer Functions //
   ////////////////////////

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(!_isBot[from] && !_isBot[to], "C:\\<windows95\\system32> kill bot");
        
        if(!_isExcludedFromFees[from] && !automatedMarketMakerPairs[to] && !_isExcludedFromFees[to]){
            require(balanceOf(to) + (amount) <= maxWalletBalance, "Balance is exceeding maxWalletBalance");
        }

        if(!_isExcludedFromFees[from] && !_isExcludedFromFees[to]){
            require(amount <= maxTxAmount ,"Amount is exceeding maxTXAmount");
        }

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

		uint256 contractTokenBalance = balanceOf(address(this));
        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if( canSwap && !swapping && swapEnabled && !automatedMarketMakerPairs[from]) {
            swapping = true;

            if(liquidityTax > 0 || marketingTax > 0){
                uint256 swapTokens = swapTokensAtAmount * (liquidityTax + marketingTax) / (totalTaxes);
                swapAndLiquify(swapTokens);
            }
            if(rewardsTax > 0){
                uint256 sellTokens = swapTokensAtAmount * (rewardsTax) / (totalTaxes);
                swapAndSendDividends(sellTokens);
            }
            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
        	uint256 fees = amount * (totalTaxes) / (1000);
          // apply an extraSellTax during a sell
          // it is divided equally into the liquidity, marketing and rewards fee
          if(automatedMarketMakerPairs[to]){
              fees += amount * (extraSellTax) / (1000);
          }
          amount = amount - (fees);
          super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(from, balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(to, balanceOf(to)) {} catch {}

        if(!swapping) {
	    	uint256 gas = gasForProcessing;

	    	try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
	    		emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
	    	}
	    	catch {}
        }
    }

    function swapAndLiquify(uint256 tokens) private {
        // Split the contract balance into halves
        uint256 denominator= (liquidityTax + marketingTax) * 2;
        uint256 tokensToAddLiquidityWith = tokens * liquidityTax / denominator;
        uint256 toSwap = tokens - tokensToAddLiquidityWith;

        uint256 initialBalance = address(this).balance;

        swapTokensForBNB(toSwap);

        uint256 deltaBalance = address(this).balance - initialBalance;
        uint256 unitBalance= deltaBalance / (denominator - liquidityTax);
        uint256 bnbToAddLiquidityWith = unitBalance * liquidityTax;

        if(bnbToAddLiquidityWith > 0){
            // Add liquidity to pancake
            addLiquidity(tokensToAddLiquidityWith, bnbToAddLiquidityWith);
        }

        // Send BNB to marketingWallet
        uint256 marketingWalletAmt = unitBalance * 2 * marketingTax;
        if(marketingWalletAmt > 0){
            payable(marketingWallet).sendValue(marketingWalletAmt);
        }
    }

    function swapTokensForBNB(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );

    }

    function swapTokensForRewardToken(uint256 tokenAmount) private {

        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = router.WETH();
        path[2] = rewardToken;

        _approve(address(this), address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(router), tokenAmount);

        // add the liquidity
        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );

    }

    function swapAndSendDividends(uint256 tokens) private{
        swapTokensForRewardToken(tokens);
        uint256 dividends = IERC20(rewardToken).balanceOf(address(this));
        bool success = IERC20(rewardToken).transfer(address(dividendTracker), dividends);

        if (success) {
            dividendTracker.distributeRewardTokenDividends(dividends);
            emit SendDividends(tokens, dividends);
        }
    }
}
