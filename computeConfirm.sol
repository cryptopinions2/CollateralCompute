pragma solidity ^0.4.25;


/*
  CollateralCompute is a collateral based method for trustlessly confirming offchain information onto the Ethereum blockchain. Computation, API, etc. results are reported, and then token holders may earn Eth by staking those tokens on whether these reports are correct. The system is designed so that, if the collateral balance is calibrated correctly, incorrect stakes will always result in a loss of Eth greater than the potential gain.
*/


contract ERC20Interface {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}
contract ApproveAndCallFallBack {
    function receiveApproval(address from, uint256 tokens, address token, bytes data) public;
}
/*
  Contracts using this to confirm external computations should implement this
*/
contract Confirmable{
  function confirm(uint index,bool confirmed);
}
contract CollateralCompute is ERC20Interface{

//ERC20 variables
  using SafeMath for uint;
  string public symbol;
  string public  name;
  uint8 public decimals;
  uint _totalSupply;
  mapping(address => uint) balances;
  mapping(address => mapping(address => uint)) allowed;

//Collateral Compute variables
  //staking
  mapping(address => uint) public userTimeout;//prevents any token transfers from this account before the specified time. Allows the staking process to freeze funds.
  mapping(address => bytes32) public lastStakedByUser;
  uint public constant BASE_TIME_TO_CONFIRM=5 minutes;
  uint public constant MINIMUM_TOKEN_STAKE=1000*10**decimals;
  uint public constant STAKE_REPLACE_MINIMUM_ADVANTAGE=20;//percent of tokens more than previous staker you must hold to replace their stake
  uint public constant STAKE_EXIT_CUTOFF=25;//if a stake escalation reaches a stake with this percent of total tokens, trigger a burn event.
  mapping(bytes32 => ComputationInfo) cInfo;
  mapping(bytes32 => mapping(uint8 => StakeInfo)) sInfo;
  uint public canBurnUntil;//when token burning is activated by stake escalation, it expires at this time
  uint public lastBurnStake;//amount of tokens staked to trigger the last burn
  uint collateralBalance;//eth held in the contract as collateral.

  //governance related variables
  uint public ICOActiveUntil;//when the latest ICO ends
  uint public ICOMaxSold;//maximum tokens  that can be purchased in the latest ICO
  uint public ICOSold;//number of tokens sold in the latest ICO so far
  uint public ICOPrice;//price of a token in the latest ICO

  uint public liquidationActiveUntil;//when latest liquidation ends
  uint public liquidationEth;//how much is being distributed
  uint public liquidationTokensStored;//how many tokens are currently being staked towards liquidationEth

  event Warning();
  event BurnEvent();

  modifier ICOActive(){
    require(now<ICOActiveUntil);
    _;
  }
  modifier noTimeout(){
    require(now>=userTimeout[msg.sender]);
    _;
  }
  modifier burnActive(){
    require(now<canBurnUntil);
    _;
  }
  struct ComputationInfo{
    address contractAddress;
    uint index;
    uint fee;
  }
  struct StakeInfo{
    address staker;
    uint tokensStaked;
    uint timeCompleted;
    bool claimedCorrect;
  }

  function registerComputation(uint i) payable{
    cInfo[keccak256(abi.encodePacked(msg.sender,i))]=ComputationInfo({contractAddress:msg.sender,index:i,fee:msg.value});
  }

  /*
    Stake tokens to declare that the specified registered computation or claim is correct. If your claim disagrees with the previous, you must stake twice as many tokens as them (tokens parameter is the max you are willing to stake, will stake as many as needed up to that number). The amount of time the computation will take to finalize increases with every new competing stake.

    TODO: currently trying to make a claim that is the same as the previous reverts the transaction. The plan is to instead replace the previous claim if you have more tokens than the account that made it, to avoid a gas war.

    note: index parameter is an identifier for the computation within the contract, the local variable lastIndex is totally separate (index of claim to that computation).
  */
  function stakeComputationCorrect(address contractAddress,uint index,bool correct,uint tokens) public{
    require(balances[msg.sender]>=tokens);
    bytes32 computationHash=keccak256(abi.encodePacked(contractAddress,index));
    uint8 lastIndex=0;
    uint tokensToStake=MINIMUM_TOKEN_STAKE;
    while(sInfo[computationHash][lastIndex].staker!=0){
      lastIndex=lastIndex+1;
    }
    tokensToStake=tokensToStake.mul(2**lastIndex);
    uint timeout=BASE_TIME_TO_CONFIRM.mul(2**lastIndex);
    assert(lastIndex<10);//sanity check
    if(lastIndex!=0){
    //must be at least twice the tokens and the opposite claim
      require(sInfo[computationHash][lastIndex-1].tokensStaked<=tokens/2 && sInfo[computationHash][lastIndex-1].claimedCorrect!=correct);
      //replace previous claim if it is the same and you have more tokens
      //if(sInfo[computationHash][lastIndex-1].claimedCorrect==correct){
        //lastIndex--;
        //balances[sInfo[computationHash][lastIndex-1].staker]=balances[sInfo[computationHash][lastIndex-1].staker].add(sInfo[computationHash][lastIndex-1].tokensStaked);
        //do something with previous staker's cooldown time? Exploitable if just set to 0 because of possibility of more than one active stake
      //}
    }
    require(balances[msg.sender]>=tokensToStake);
    balances[msg.sender]=balances[msg.sender].sub(tokensToStake);
    sInfo[computationHash][lastIndex]=StakeInfo(msg.sender,tokensToStake,now+timeout,correct);
    lastStakedByUser[msg.sender]=computationHash;
    /*
      Freeze user's tokens for an amount of time based on the staking escalation. If you are backing the wrong outcome to the point where the market value of the token is damaged, you won't be able to dump your tokens for a while.
    */
    if(userTimeout[msg.sender]<now+timeout){
      userTimeout[msg.sender]=now+timeout;
    }
    /*
      Enter emergency state if staking escalated far enough. This allows everyone EXCEPT the final staker to drain the collateral during the staking period (which should be considerably long at this stage of escalation), by burning tokens.

      It is assumed that the market value of a token, with the contract in a functional, correct-result-giving state should be above the value that can be obtained by burning for collateral. This should be achieved by the token governance mechanism adjusting fees, minting and selling tokens to add more collateral, and divesting portions of the collateral pool as dividends, in order to keep a healthy balance. There should be tools to measure this balance, and create an incentive for voting token holders to maintain it in order to signal to the market that the collateral system is stable.

      The second assumption, also maintained by the same mechanisms, is that the value of tokens staked at this level is greater than any possible profit from finalizing an erroneous result (or multiple, if that could be part of an overarching bad-actor strategy). Since this token is meant to be deployed for single, custom purposes, it should be achievable for governance to make a good analysis of the profit ceiling for that given domain.

      If these are true, and the market is kept informed and rational, then staking a bad result at this level should always cause a significant overall loss to the bad actor. People will see that a plurality of tokens are controlled by a bad actor, and realize that the contract no longer has utility, and therefore no longer has potential to earn the fees that give the tokens their value. In this case it is in everyones interest to burn their tokens to drain the contract, leaving the bad actor with nothing except control over an abandoned contract once their tokens are no longer frozen. At this point the contract could be redeployed. This scenario is unlikely because of the disincentive involved in throwing away a large sum of Ethereum.

      Staking a correct result at this level will also trigger the ability to drain the collateral, but in this case the utility of the contract remains intact. To avoid the potential for bad actors staking at lower levels on other computations during the burn period, profiting from wrong results to make up for the loss of burning tokens compared to their market value, the escalation stage right before the burn-level-stake will be a warning period where use of the contract will be advised against for the duration. There should be no incentive to burn tokens rather than retain them if their market value is higher than the burn value.

      Because you can only lose Eth by staking a bad result, there is a strong incentive not to escalate stakes at all, and the following conditions are unlikely to be achieved.
    */
    //if(sInfo[computationHash][lastIndex].tokensStaked >  WARNING_CUTOFF){
      //emit Warning();
    //}
    //if(sInfo[computationHash][lastIndex].tokensStaked >  STAKE_EXIT_CUTOFF){
      //require(now<canBurnUntil);//ensures only one burn event at a time
      //emit BurnEvent();
      //lastBurnStake=sInfo[computationHash][lastIndex].tokensStaked;
      //ALLOW TOKEN SELLING FOR THE STAKING PERIOD HERE
    //}
  }
  function stakeExitCutoffTokens() public view returns(uint){
    return _totalSupply.mul(STAKE_EXIT_CUTOFF).div(100);
  }
  /*
    Finalizes computations if the required amount of time has passed.
  */
  function finalizeComputation(address contractAddress,uint index){
    bytes32 computationHash=keccak256(abi.encodePacked(contractAddress,index));
    uint8 lastIndex=0;
    while(sInfo[computationHash][lastIndex].staker!=0){//find the last stake
      lastIndex=lastIndex+1;
    }
    if(lastIndex==0){
      revert();//no reason to be calling this, computation is not confirmed by anyone
    }
    lastIndex--;
    //enough time must have passed. The higher the level of escalation, the more time people should have to consider the correctness of the computation and have a chance to dispute it.
    require(now>=sInfo[computationHash][lastIndex].timeCompleted);
    bool outcome=sInfo[computationHash][lastIndex].claimedCorrect;
    bool outcomePaid=false;
    for(uint8 i=0;i<lastIndex;i++){
      //if this user is one of the winners
      if(outcome==sInfo[computationHash][i].claimedCorrect){
        if(!outcomePaid){//the first correct staker gets the initial fee
          //SEND PAYMENT TO TOKEN HOLDER HERE sInfo[computationHash][i].staker cInfo[computationHash].fee
          outcomePaid=true;
        }
        if(i>0){
          //user wins tokens of previous (erroneous) staker
          balances[sInfo[computationHash][i].staker]=balances[sInfo[computationHash][i].staker].add(sInfo[computationHash][i-1].tokensStaked);
        }
        //return staked tokens to user
        balances[sInfo[computationHash][i].staker]=balances[sInfo[computationHash][i].staker].add(sInfo[computationHash][i].tokensStaked);
      }
    }
    //declare outcome to the source contract
    Confirmable(contractAddress).confirm(index,outcome);
  }

  /*
    If staking on a computation escalates to the limit, everyone except the final staker may retrieve their share of the collateral (final staker has a longer timeout than anyone else). Burns all your tokens (only call this if the contract has undergone a hostile takeover and tokens now have zero real value).
  */
  function burnTokens() public noTimeout burnActive{
    //consider the total supply minus the tokens staked to trigger it. This way, the Eth associated with those tokens is distributed to everyone else.
    uint payout=balances[msg.sender].mul(collateralBalance).div(_totalSupply.sub(lastBurnStake));
    collateralBalance=collateralBalance.sub(payout);
    _totalSupply=_totalSupply.sub(balances[msg.sender]);
    balances[msg.sender]=0;
    msg.sender.transfer(payout);
  }
  /*
    Tokens are minted here. All Eth goes to the collateral pool. Token holders must vote on a new ICO to issue more tokens. Ideally this should only be done when the state of the market and volume of eth being processed through the associated dapp warrants more collateral.
  */
  function buyTokens() public payable noTimeout ICOActive{
    uint tokensToBuy=msg.value.div(ICOPrice);
    balances[msg.sender]=balances[msg.sender].add(tokensToBuy);
    _totalSupply=_totalSupply.add(tokensToBuy);
    collateralBalance=collateralBalance.add(msg.value); //ALL of the cost of tokens goes towards collateral.
    require(ICOSold.add(tokensToBuy)<=ICOMaxSold);
    ICOSold=ICOSold.add(tokensToBuy);
  }

  /*
    When collateral eth is divested, or if a portion of fees are allocated to token holders in general, they go into a pool. When that pool exceeds a threshold, token holders are given a chance to stake tokens for a share of it. After the time limit elapses, eth and tokens can be retrieved.

    (I want to do it this way instead of a typical dividends system mostly to keep the code simpler and less of an attack surface. There is the added benefit of incentivizing token holders to check on the project regularly and stay involved).

    TODO: implement
  */
  function stakeForDivs(uint tokens) public{

  }

  // ------------------------------------------------------------------------
  // Total supply
  // ------------------------------------------------------------------------
  function totalSupply() public view returns (uint) {
      return _totalSupply.sub(balances[address(0)]);
  }


  // ------------------------------------------------------------------------
  // Get the token balance for account `tokenOwner`
  // ------------------------------------------------------------------------
  function balanceOf(address tokenOwner) public view returns (uint balance) {
      return balances[tokenOwner];
  }


  // ------------------------------------------------------------------------
  // Transfer the balance from token owner's account to `to` account
  // - Owner's account must have sufficient balance to transfer
  // - 0 value transfers are allowed
  // ------------------------------------------------------------------------
  function transfer(address to, uint tokens) public noTimeout returns (bool success) {
      balances[msg.sender] = balances[msg.sender].sub(tokens);
      balances[to] = balances[to].add(tokens);
      emit Transfer(msg.sender, to, tokens);
      return true;
  }


  // ------------------------------------------------------------------------
  // Token owner can approve for `spender` to transferFrom(...) `tokens`
  // from the token owner's account
  //
  // https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20-token-standard.md
  // recommends that there are no checks for the approval double-spend attack
  // as this should be implemented in user interfaces
  // ------------------------------------------------------------------------
  function approve(address spender, uint tokens) public noTimeout returns (bool success) {
      allowed[msg.sender][spender] = tokens;
      emit Approval(msg.sender, spender, tokens);
      return true;
  }


  // ------------------------------------------------------------------------
  // Transfer `tokens` from the `from` account to the `to` account
  //
  // The calling account must already have sufficient tokens approve(...)-d
  // for spending from the `from` account and
  // - From account must have sufficient balance to transfer
  // - Spender must have sufficient allowance to transfer
  // - 0 value transfers are allowed
  // ------------------------------------------------------------------------
  function transferFrom(address from, address to, uint tokens) public returns (bool success) {
      require(now>=userTimeout[from]);
      balances[from] = balances[from].sub(tokens);
      allowed[from][msg.sender] = allowed[from][msg.sender].sub(tokens);
      balances[to] = balances[to].add(tokens);
      emit Transfer(from, to, tokens);
      return true;
  }


  // ------------------------------------------------------------------------
  // Returns the amount of tokens approved by the owner that can be
  // transferred to the spender's account
  // ------------------------------------------------------------------------
  function allowance(address tokenOwner, address spender) public view returns (uint remaining) {
      return allowed[tokenOwner][spender];
  }


  // ------------------------------------------------------------------------
  // Token owner can approve for `spender` to transferFrom(...) `tokens`
  // from the token owner's account. The `spender` contract function
  // `receiveApproval(...)` is then executed
  // ------------------------------------------------------------------------
  function approveAndCall(address spender, uint tokens, bytes data) public noTimeout returns (bool success) {
      allowed[msg.sender][spender] = tokens;
      emit Approval(msg.sender, spender, tokens);
      ApproveAndCallFallBack(spender).receiveApproval(msg.sender, tokens, this, data);
      return true;
  }


  // ------------------------------------------------------------------------
  // Don't accept ETH
  // ------------------------------------------------------------------------
  function () public payable {
      revert();
  }
}
// ----------------------------------------------------------------------------
// Safe maths
// ----------------------------------------------------------------------------
library SafeMath {
    function add(uint a, uint b) internal pure returns (uint c) {
        c = a + b;
        require(c >= a);
    }
    function sub(uint a, uint b) internal pure returns (uint c) {
        require(b <= a);
        c = a - b;
    }
    function mul(uint a, uint b) internal pure returns (uint c) {
        c = a * b;
        require(a == 0 || c / a == b);
    }
    function div(uint a, uint b) internal pure returns (uint c) {
        require(b > 0);
        c = a / b;
    }
}
