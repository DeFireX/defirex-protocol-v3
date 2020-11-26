pragma solidity ^0.5.16;

import "@openzeppelin/upgrades/contracts/Initializable.sol";

import "../access/Adminable.sol";

import "../utils/DSMath.sol";
import "../utils/UniversalERC20.sol";

import "../constants/ConstantAddressesMainnet.sol";

import "../compound/interfaces/ICToken.sol";
import "../interfaces/IDfFinanceDeposits.sol";
import "../interfaces/IToken.sol";
import "../interfaces/IDfDepositToken.sol";
import "../interfaces/IPriceOracle.sol";

interface IComptroller {
    function oracle() external view returns (IPriceOracle);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline
    ) external returns (uint[] memory amounts);
}

contract DfTokenizedDeposit is
    Initializable,
    Adminable,
    DSMath,
    ConstantAddresses
{
    using UniversalERC20 for IToken;


    struct ProfitData {
        uint64 blockNumber;
        uint64 daiProfit; // div 1e12 (6 dec)
        uint64 usdtProfit;
    }


    ProfitData[] public profits;

    IDfDepositToken public token;
    address public dfWallet;

    // IDfFinanceDeposits public constant dfFinanceDeposits = IDfFinanceDeposits(0xCa0648C5b4Cea7D185E09FCc932F5B0179c95F17); // Kovan
    IDfFinanceDeposits public constant dfFinanceDeposits = IDfFinanceDeposits(0xFff9D7b0B6312ead0a1A993BF32f373449006F2F); // Mainnet

    mapping(address => uint64) public lastProfitDistIndex;

    address usdtExchanger;

    event CompSwap(uint256 timestamp, uint256 compPrice);
    event Profit(address indexed user, uint64 index, uint64 usdtProfit, uint64 daiProfit);

    // new
    address public liquidityProviderAddress;
    // colliteral rate
    uint256 public crate;
    mapping(address => uint256) public fundsUnwinded;

    IUniswapV2Router02 constant uniRouter = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); // same for kovan and mainnet

    IDfDepositToken public tokenETH;
    IDfDepositToken public tokenUSDC;

    address constant ethProfitDepositAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    uint256 public rewardFee;
    uint256 public ethCoef;
    event Credit(address token, uint256 amount);
    // new

    function initialize() public initializer {
        address payable curOwner = 0xdAE0aca4B9B38199408ffaB32562Bf7B3B0495fE;
        Adminable.initialize(curOwner);  // Initialize Parent Contract

        IToken(DAI_ADDRESS).approve(address(dfFinanceDeposits), uint256(-1));
    }

    // returns tokens left
    function fastDeposit(IDfDepositToken dTokenAddress, address assetAddress, uint256 amount) internal returns (uint256) {
        address _liquidityProviderAddress = liquidityProviderAddress;
        if (dTokenAddress.balanceOf(_liquidityProviderAddress) >= amount && dTokenAddress.allowance(address(this), _liquidityProviderAddress) >= amount) {
            if (assetAddress == WETH_ADDRESS) {
                address(uint160(_liquidityProviderAddress)).transfer(amount);
            } else {
                IToken(assetAddress).transferFrom(msg.sender, _liquidityProviderAddress, amount);
            }

            dTokenAddress.transferFrom(_liquidityProviderAddress, msg.sender, amount);
            return 0;
        }
        return amount;
    }

    function deposit(uint256 amountDAI, uint256 amountUSDC, address flashloanFromAddress) public payable {
        require(msg.sender == tx.origin);
        require(token != IDfDepositToken(0x0));
        uint256 amountETH = msg.value;

        // fast deposit
        if (amountDAI > 0) amountDAI = fastDeposit(token, DAI_ADDRESS, amountDAI);

        if (amountETH > 0) {
            amountETH = fastDeposit(tokenETH, WETH_ADDRESS, amountETH);
        }
        if (amountUSDC > 0) {
            amountUSDC = fastDeposit(tokenUSDC, USDC_ADDRESS, amountUSDC);
        }

        if (amountDAI > 0 || amountETH > 0 || amountUSDC > 0)
        {
            uint256 flashLoanDAI;
            uint256 flashLoanUSDC;
            (flashLoanDAI, flashLoanUSDC) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH);

            if (amountDAI  > 0)  IToken(DAI_ADDRESS).transferFrom(msg.sender, address(dfWallet), amountDAI);
            if (amountUSDC > 0)  IToken(USDC_ADDRESS).transferFrom(msg.sender, address(dfWallet), amountUSDC);

            address _dfWalletNew = dfFinanceDeposits.deposit.value(amountETH)(dfWallet, amountDAI, amountUSDC, 0, flashLoanDAI, flashLoanUSDC, IDfFinanceDeposits.FlashloanProvider.DYDX, flashloanFromAddress);
            if (dfWallet == address(0)) dfWallet = _dfWalletNew;

            if (amountDAI > 0) token.mint(msg.sender, amountDAI);
            if (amountUSDC > 0) tokenUSDC.mint(msg.sender, amountUSDC);
            if (amountETH > 0) tokenETH.mint(msg.sender, amountETH);
        }
    }

    function burnTokenFast(IDfDepositToken tokenDeposit, IToken targetAsset, uint256 amount, address _liquidityProviderAddress) internal returns (uint256) {
        uint256 _fundsUnwinded = fundsUnwinded[address(targetAsset)];
        // exchange tokens if required amount unwinded exists
        if (_fundsUnwinded >= amount) {
            tokenDeposit.burnFrom(msg.sender, amount);
            if (address(targetAsset) == WETH_ADDRESS) {
                address(uint160(msg.sender)).transfer(amount);
            } else {
                IToken(targetAsset).transfer(msg.sender, amount);
            }

            fundsUnwinded[address(targetAsset)] = sub(_fundsUnwinded, amount);
            return 0;
        } else {
            if (targetAsset.balanceOf(_liquidityProviderAddress) >= amount && targetAsset.allowance(address(this), _liquidityProviderAddress) >= amount) {
                // exchnage tokens with low fee via liquidityProviderAddress
                tokenDeposit.transferFrom(msg.sender, _liquidityProviderAddress, amount);
                if (address(targetAsset) == WETH_ADDRESS) {
                    // WETH (this) => ETH (withdraw) => ETH (msg.sender)
                    targetAsset.transferFrom(_liquidityProviderAddress, address(this), amount);
                    IToken(WETH_ADDRESS).withdraw(amount);
                    address(uint160(msg.sender)).transfer(amount);
                } else {
                    targetAsset.transferFrom(_liquidityProviderAddress, msg.sender, amount);
                }
                return 0;
            } else {
                return amount;
            }
        }
    }

    function getFlashLoanAmounts(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH) internal returns (uint256 flashLoanDAI, uint256 flashLoanUSDC) {
        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        uint256 _crate = crate;
        uint256 _daiPrice = compOracle.price("DAI");
        flashLoanDAI = amountDAI * _crate / 100;
        if (amountUSDC > 0) flashLoanUSDC = amountUSDC * _crate / 100;
        if (amountETH > 0) flashLoanDAI += amountETH * compOracle.price("ETH") * _daiPrice / 1e12 * 100 / ethCoef * (_crate + 100) / 100; // extract half in DAI ( / 2)
    }

    function burnTokens(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, address flashLoanFromAddress) public {
        require(msg.sender == tx.origin);
        address _liquidityProviderAddress = liquidityProviderAddress;
        if (amountDAI > 0) amountDAI = burnTokenFast(token, IToken(DAI_ADDRESS), amountDAI, _liquidityProviderAddress);
        if (amountUSDC > 0) amountUSDC = burnTokenFast(tokenUSDC, IToken(USDC_ADDRESS), amountUSDC, _liquidityProviderAddress);
        if (amountETH > 0) amountETH = burnTokenFast(tokenETH, IToken(WETH_ADDRESS), amountETH, _liquidityProviderAddress);

        if (amountDAI > 0 || amountUSDC > 0 || amountETH > 0) {

            uint256 flashLoanDAI;
            uint256 flashLoanUSDC;
            (flashLoanDAI, flashLoanUSDC) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH);

            dfFinanceDeposits.withdraw(dfWallet, amountDAI, amountUSDC, amountETH, 0, msg.sender, flashLoanDAI, flashLoanUSDC, IDfFinanceDeposits.FlashloanProvider.DYDX, flashLoanFromAddress);

            if (amountDAI > 0) token.burnFrom(msg.sender, amountDAI);
            if (amountUSDC > 0) tokenUSDC.burnFrom(msg.sender, amountUSDC);
            if (amountETH > 0) tokenETH.burnFrom(msg.sender, amountETH);
        }
    }

    function sync(address flashLoanFromAddress, uint256 _newCRate, uint256 _newEthCoef) public onlyOwnerOrAdmin {
        uint256 amountDAI = sub(token.totalSupply(), fundsUnwinded[DAI_ADDRESS]);
        uint256 amountUSDC = address(tokenUSDC) == address(0x0) ? 0 : sub(tokenUSDC.totalSupply(), fundsUnwinded[USDC_ADDRESS]);
        uint256 amountETH =  address(tokenETH) == address(0x0) ? 0 : sub(tokenETH.totalSupply(), fundsUnwinded[WETH_ADDRESS]);
        unwindFunds(amountDAI, amountUSDC, amountETH, flashLoanFromAddress);
        if (_newCRate > 100) crate = _newCRate;
        if (_newEthCoef > 100) ethCoef = _newEthCoef;
        boostFunds(amountDAI, amountUSDC, amountETH, flashLoanFromAddress);
        // TODO: добавить валидацию
    }

    function unwindFunds(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, address flashLoanFromAddress) public onlyOwnerOrAdmin {
        uint256 flashLoanDAI;
        uint256 flashLoanUSDC;
        (flashLoanDAI, flashLoanUSDC) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH);

        uint256 balanceDAI;
        uint256 balanceUSDC;
        if (amountDAI > 0) balanceDAI = IToken(DAI_ADDRESS).balanceOf(address(this));
        if (amountUSDC > 0) balanceUSDC = IToken(USDC_ADDRESS).balanceOf(address(this));
        // amountETH = -1
        dfFinanceDeposits.withdraw(dfWallet, amountDAI, amountUSDC, amountETH, 0, address(this), flashLoanDAI, flashLoanUSDC, IDfFinanceDeposits.FlashloanProvider.DYDX, flashLoanFromAddress);

        if (amountDAI > 0) {
            balanceDAI = sub(IToken(DAI_ADDRESS).balanceOf(address(this)), balanceDAI);
            if (amountDAI > balanceDAI) emit Credit(DAI_ADDRESS, amountDAI - balanceDAI); // system lose via credit
            fundsUnwinded[DAI_ADDRESS] += amountDAI;
        }
        if (amountUSDC > 0) {
            balanceUSDC = sub(IToken(USDC_ADDRESS).balanceOf(address(this)), balanceUSDC);
            if (amountUSDC > balanceUSDC) emit Credit(USDC_ADDRESS, balanceUSDC - amountUSDC); // system lose via credit
            fundsUnwinded[USDC_ADDRESS] += amountUSDC;
        }
        if (amountETH > 0) {
            require(address(this).balance >= amountETH);
            fundsUnwinded[WETH_ADDRESS] += amountETH;
        }

    }

    function boostFunds(uint256 amountDAI, uint256 amountUSDC, uint256 amountETH, address flashLoanFromAddress) public onlyOwnerOrAdmin  {
        if (amountDAI > fundsUnwinded[DAI_ADDRESS]) amountDAI = fundsUnwinded[DAI_ADDRESS];
        if (amountUSDC > fundsUnwinded[USDC_ADDRESS]) amountUSDC = fundsUnwinded[USDC_ADDRESS];
        if (amountETH > fundsUnwinded[WETH_ADDRESS]) amountETH = fundsUnwinded[WETH_ADDRESS];

        uint256 flashLoanDAI;
        uint256 flashLoanUSDC;
        (flashLoanDAI, flashLoanUSDC) = getFlashLoanAmounts(amountDAI, amountUSDC, amountETH);
        if (amountDAI  > 0)  IToken(DAI_ADDRESS).transfer(address(dfWallet), amountDAI);
        if (amountUSDC > 0)  IToken(USDC_ADDRESS).transfer(address(dfWallet), amountUSDC);
        dfFinanceDeposits.deposit.value(amountETH)(dfWallet, amountDAI, amountUSDC, 0, flashLoanDAI, flashLoanUSDC, IDfFinanceDeposits.FlashloanProvider.DYDX, flashLoanFromAddress);
        if (amountDAI > 0) fundsUnwinded[DAI_ADDRESS] = sub(fundsUnwinded[DAI_ADDRESS], amountDAI);
        if (amountUSDC > 0) fundsUnwinded[USDC_ADDRESS] = sub(fundsUnwinded[USDC_ADDRESS], amountUSDC);
        if (amountETH > 0) fundsUnwinded[WETH_ADDRESS] = sub(fundsUnwinded[WETH_ADDRESS], amountETH);
    }


    function userShare(address userAddress, uint256 snapshotId) view public returns (uint256 totalLiquidity, uint256 totalSupplay) {
        uint256 priceETH = tokenETH.prices(snapshotId);
        uint256 offset = 0; // TODO: offset for new tokens
        totalLiquidity = token.balanceOfAt(userAddress, snapshotId) +
                            mul(tokenETH.balanceOfAt(userAddress, snapshotId + offset), priceETH) / 1e6 * 100 / ethCoef + // ETH price 6 decimals
                            tokenUSDC.balanceOfAt(userAddress, snapshotId  + offset) * 1e12; // USDC 6 decimals => 18, suggest 1 DAI == 1 USDC

        totalSupplay = token.totalSupplyAt(snapshotId) +
                            mul(tokenETH.totalSupplyAt(snapshotId), priceETH) / 1e6 + // ETH price 6 decimals
                            tokenUSDC.totalSupplyAt(snapshotId) * 1e12; // USDC 6 decimals => 18
    }

    function getUserProfitFromCustomIndex(address userAddress, uint64 fromIndex, uint256 max) public view returns(
        uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index
    ) {
        if (profits.length < max) max = profits.length;

        index = fromIndex;

        for(; index < max; index++) {
            ProfitData memory p = profits[index];
            uint256 balanceAtBlock;
            uint256 totalSupplyAt;
            (balanceAtBlock, totalSupplyAt) = userShare(userAddress, index + 1);

            uint256 profitUsdt = wdiv(wmul(uint256(p.usdtProfit), balanceAtBlock), totalSupplyAt);
            uint256 profitDai = wdiv(wmul(mul(uint256(p.daiProfit), 1e12),balanceAtBlock), totalSupplyAt);
            totalUsdtProfit = add(totalUsdtProfit, profitUsdt);
            totalDaiProfit = add(totalDaiProfit, profitDai);
        }
    }

    function calcUserProfit(address userAddress, uint256 max) public view returns(
        uint256 totalUsdtProfit, uint256 totalDaiProfit, uint64 index
    ) {
        (totalUsdtProfit, totalDaiProfit, index) = getUserProfitFromCustomIndex(userAddress, lastProfitDistIndex[userAddress], max);
    }

    function userClaimProfitOptimized(uint64 fromIndex, uint64 lastIndex, uint256 totalUsdtProfit, uint256 totalDaiProfit, uint8 v, bytes32 r, bytes32 s, bool isReinvest) public {

        require(msg.sender == tx.origin);
        uint64 currentIndex = lastProfitDistIndex[msg.sender];
        require(currentIndex == fromIndex);

        // check signature
        uint256 versionNonce = 1;
        bytes32 hash = sha256(abi.encodePacked(this, versionNonce, msg.sender, fromIndex, lastIndex, totalUsdtProfit, totalDaiProfit));
        address src = ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), v, r, s);
        require(admins[src] == true, "Access denied");

        require(currentIndex < lastIndex);

        lastProfitDistIndex[msg.sender] = lastIndex;

        if (totalUsdtProfit > 0) {
            IToken(USDT_ADDRESS).universalTransfer(msg.sender, totalUsdtProfit);
        }

        if (totalDaiProfit > 0) {
            IToken(DAI_ADDRESS).transfer(msg.sender, totalDaiProfit);
            if (isReinvest) {
                deposit(totalDaiProfit, 0, address(0x0));
            }
        }
    }

    function userClaimProfit(uint64 max) public {
        require(msg.sender == tx.origin);

        uint64 index;
        uint256 totalUsdtProfit;
        uint256 totalDaiProfit;
        (totalUsdtProfit, totalDaiProfit, index) = calcUserProfit(msg.sender, max);

        lastProfitDistIndex[msg.sender] = index;

        if (totalUsdtProfit > 0) {
            IToken(USDT_ADDRESS).universalTransfer(msg.sender, totalUsdtProfit);
        }

        if (totalDaiProfit > 0) {
            IToken(DAI_ADDRESS).transfer(msg.sender, totalDaiProfit);
        }
    }

    function setUSDTExchangeAddress(address _newAddress) public onlyOwnerOrAdmin {
        usdtExchanger = _newAddress;
    }

    function adminClaimProfitAndInternalSwapToDAI(uint256 _compPriceInDai, address[] memory ctokens) public onlyOwnerOrAdmin returns (uint256 amountComps, uint256 amountDai) {
        // Claim comps without exchange
        amountComps = dfFinanceDeposits.claimComps(dfWallet, ctokens);
        amountDai = wmul(amountComps, _compPriceInDai); // COMP to USDT

        IToken(DAI_ADDRESS).transferFrom(usdtExchanger, address(this), amountDai);
        IToken(COMP_ADDRESS).transfer(usdtExchanger, amountComps);

        ProfitData memory p;
        p.blockNumber = uint64(block.number);

        uint256 _fee = amountDai * rewardFee / 100;
        IToken(DAI_ADDRESS).transfer(owner, _fee);
        amountDai = sub(amountDai, _fee);

        p.daiProfit = p.daiProfit + uint64(amountDai / 1e12); // // reduce decimals to 1e6
        profits.push(p);

        token.snapshot();
        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        if (address(tokenETH) != address(0x0)) tokenETH.snapshot(compOracle.price("ETH"));
        if (address(tokenUSDC) != address(0x0)) tokenUSDC.snapshot();

        emit CompSwap(block.timestamp, _compPriceInDai);
    }

    function getCompPriceInDAI() view public returns(uint256) {
        //  price not less that price from oracle with 3% slippage
        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        return compOracle.price("COMP") * 1e18 / compOracle.price("DAI") * 97 / 100;
    }

    // profit in DAI
    function adminClaimProfit(address[] memory path, uint256 minAmount, address[] memory ctokens) public onlyOwnerOrAdmin returns (uint256) {
        require(path[path.length - 1] == DAI_ADDRESS);

//        userShare( profits.length)
        uint256 amount = dfFinanceDeposits.claimComps(dfWallet, ctokens);
        ProfitData memory p;
        p.blockNumber = uint64(block.number);
        // TODO use uniswap pool to convert
        if (IToken(COMP_ADDRESS).allowance(address(this), address(uniRouter)) != uint256(-1)) {
            IToken(COMP_ADDRESS).approve(address(uniRouter), uint256(-1));
        }
        uint256 balance = IToken(DAI_ADDRESS).balanceOf(address(this));
        uint256 minDaiFromSwap = wmul(getCompPriceInDAI(), amount);
        minDaiFromSwap = 1; // TODO: for Kovan test, remove it in mainnet
        uniRouter.swapExactTokensForTokens(amount, minDaiFromSwap, path, address(this), now + 1000);

        uint256 _reward = sub(IToken(DAI_ADDRESS).balanceOf(address(this)), balance);
        require(_reward >= minAmount);

        emit CompSwap(block.timestamp, wdiv(_reward, amount));

        uint256 _fee = _reward * rewardFee / 100;
        IToken(DAI_ADDRESS).transfer(owner, _fee);
        _reward = sub(_reward, _fee);
        p.daiProfit = uint64(_reward / 1e12); // reduce decimals to 1e6
        profits.push(p);

        token.snapshot();

        IPriceOracle compOracle = IComptroller(COMPTROLLER).oracle();
        if (address(tokenETH) != address(0x0)) tokenETH.snapshot(compOracle.price("ETH"));
        if (address(tokenUSDC) != address(0x0)) tokenUSDC.snapshot();

        return p.daiProfit;
    }

    function setLiquidityProviderAddress(address _newAddress) public onlyOwner {
        liquidityProviderAddress = _newAddress;
    }

    function setCRateOnce(uint256 _newRate) public onlyOwner {
        require(crate == 0 && _newRate < 295);
        crate = _newRate;
    }


    function setupTokenETHOnce(address _newAddress) public onlyOwner {
        require(address(tokenETH) == address(0x0));
        tokenETH = IDfDepositToken(_newAddress);
    }

    function setupTokenUSDCOnce(address _newAddress) public onlyOwner {
        require(address(tokenUSDC) == address(0x0));
        tokenUSDC = IDfDepositToken(_newAddress);
    }

    function setRewardFee(uint256 _newRewardFee) public onlyOwner {
        require(_newRewardFee < 50);
        rewardFee = _newRewardFee;
    }

    function changeEthCoef(uint256 _newCoef) public onlyOwnerOrAdmin {
        require(_newCoef >= 200);
        ethCoef = _newCoef;
    }

    // **FALLBACK functions**
    function() external payable {}
}