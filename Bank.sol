//SPDX-License-Identifier: Unlicense
pragma solidity 0.7.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IBank.sol";
import "./interfaces/IPriceOracle.sol";
import "./libraries/Math.sol";

contract Bank is IBank {
    
    address private priceOracle;
    address private hakToken;
    address private ethMagic = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    mapping(address => mapping(address => Account)) public accounts;
    mapping(address => Account) public loans;

    constructor(address _priceOracle, address _hakToken) {
        priceOracle = _priceOracle;
        hakToken = _hakToken;
    }
    
    function _calcInterest(address token) private view returns (uint){
        uint blocks = DSMath.sub(block.number, accounts[msg.sender][token].lastInterestBlock);
        uint i = DSMath.mul(accounts[msg.sender][token].deposit, 300) / 10000;
        uint amount = DSMath.mul(i, blocks) / 100;
        return amount;
    }
    
    function _calcInterestLoan(address token) private view returns (uint){
        uint blocks = DSMath.sub(block.number, loans[msg.sender].lastInterestBlock);
        uint i = DSMath.mul(loans[msg.sender].deposit, 500) / 10000;
        uint amount = DSMath.mul(i, blocks) / 100;
        return amount;
    }
    
    
    function _block(address token) public view returns (uint){
        return block.number;
    }
    
    function deposit(address token, uint256 amount) payable external override returns (bool) {
        require(token == hakToken || token == ethMagic, "token not supported");
        if (token == ethMagic){ 
            require(msg.value == amount, "msg.value != amount");
            require(amount > 0, "amount must be positive");
        }else if(token == hakToken){
            uint256 allowance = ERC20(hakToken).allowance(msg.sender, address(this));
            require(allowance >= amount, "Check the token allowance");
            require(ERC20(hakToken).transferFrom(msg.sender, address(this), amount));   
        }
        accounts[msg.sender][token].interest = DSMath.add(accounts[msg.sender][token].interest, _calcInterest(token));
        accounts[msg.sender][token].lastInterestBlock = block.number;
        accounts[msg.sender][token].deposit = DSMath.add(accounts[msg.sender][token].deposit, amount);
        emit Deposit(msg.sender, token, amount);
        return true;
    }

    function withdraw(address token, uint256 amount) external override returns (uint256) {
        require(token == hakToken || token == ethMagic, "token not supported");
        require(amount <= address(this).balance, "no balance in contract");
        require(getBalance(token) != 0, "no balance");
        require(amount <= getBalance(token), "amount exceeds balance");
        accounts[msg.sender][token].interest = DSMath.add(accounts[msg.sender][token].interest, _calcInterest(token));
        accounts[msg.sender][token].lastInterestBlock = block.number;
        if(amount == 0){
            amount = getBalance(token);
            accounts[msg.sender][token].deposit = 0;
            accounts[msg.sender][token].interest = 0;
        }else{
            if(amount > accounts[msg.sender][token].interest){
                amount = DSMath.sub(amount, accounts[msg.sender][token].interest);
                accounts[msg.sender][token].interest = 0;
                accounts[msg.sender][token].deposit = DSMath.sub(accounts[msg.sender][token].deposit, amount);
            }else{
                accounts[msg.sender][token].interest = DSMath.sub(accounts[msg.sender][token].interest, amount);
            }
        }
        if(token == ethMagic){
            msg.sender.transfer(amount);
        }else if (token == hakToken){
            require(ERC20(hakToken).transfer(msg.sender, amount));      
        }
        emit Withdraw(msg.sender, token, amount);
        return amount;
    }

    function borrow(address token, uint256 amount) external override returns (uint256) {
        require(token == ethMagic, "token not supported");
        require(getBalance(hakToken) > 0, "no collateral deposited");
        
        loans[msg.sender].interest = DSMath.add(loans[msg.sender].interest, _calcInterestLoan(token));
        loans[msg.sender].lastInterestBlock = block.number;
        uint bal = getBalance(hakToken);
        
        if(amount == 0){
            uint a = DSMath.mul(DSMath.mul(IPriceOracle(priceOracle).getVirtualPrice(hakToken) / 1000000000000000000 , bal), 10000);
            a = DSMath.sub(a, DSMath.mul(DSMath.add(loans[msg.sender].deposit, loans[msg.sender].interest), 15000)) / 15000;
            amount = a;
        }
        uint ratio = DSMath.mul(DSMath.mul(IPriceOracle(priceOracle).getVirtualPrice(hakToken) / 1000000000000000000 , bal), 10000);
        ratio = ratio / DSMath.add(amount, DSMath.add(loans[msg.sender].deposit, loans[msg.sender].interest));
        require(ratio >= 15000, "borrow would exceed collateral ratio");
    
        loans[msg.sender].deposit = DSMath.add(loans[msg.sender].deposit, amount);
        msg.sender.transfer(amount);
        emit Borrow(msg.sender, token, amount, ratio);
        return ratio;
    }

    function repay(address token, uint256 amount) payable external override returns (uint256) {
        require(token == ethMagic, "token not supported");
        require(loans[msg.sender].deposit > 0, "nothing to repay");
        require(msg.value >= amount, "msg.value < amount to repay");
        loans[msg.sender].interest = DSMath.add(loans[msg.sender].interest, _calcInterestLoan(token));
        loans[msg.sender].lastInterestBlock = block.number;
        if(amount == DSMath.add(loans[msg.sender].deposit, loans[msg.sender].interest)){
            loans[msg.sender].interest = 0;
            loans[msg.sender].deposit = 0;
        }else if(amount >= loans[msg.sender].interest){
            amount = DSMath.sub(amount, loans[msg.sender].interest);
            loans[msg.sender].interest = 0;
            loans[msg.sender].deposit = DSMath.sub(loans[msg.sender].deposit, amount);
        }else if(amount < loans[msg.sender].interest){
            loans[msg.sender].interest = DSMath.sub(loans[msg.sender].interest, amount);   
        }
        emit Repay(msg.sender, token, loans[msg.sender].deposit);
        return loans[msg.sender].deposit;
        
    }

    function liquidate(address token, address account) payable external override returns (bool) {
        require(token == hakToken, "token not supported");
    }

    function getCollateralRatio(address token, address account) view public override returns (uint256) {
        require(token == hakToken || token == ethMagic, "token not supported");
        
        
        uint denominator = DSMath.add(DSMath.add(loans[account].deposit, loans[account].interest), _calcInterestLoan(token));
        uint numerator = getBalance(token);
        if(token == hakToken){
            numerator = DSMath.mul(IPriceOracle(priceOracle).getVirtualPrice(hakToken) / 1000000000000000000, numerator);    
        }
        if(denominator == 0) return type(uint256).max;
        return (numerator * 10000)/ denominator;
    }

    function getBalance(address token) view public override returns (uint256) {
        require(token == hakToken || token == ethMagic, "token not supported");
        return DSMath.add(DSMath.add(accounts[msg.sender][token].deposit, accounts[msg.sender][token].interest), _calcInterest(token));
    }
}
