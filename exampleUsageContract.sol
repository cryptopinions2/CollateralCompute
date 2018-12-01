pragma solidity ^0.4.25;


contract CollateralCompute{
  function registerComputation(uint index) payable;
}
contract Confirmable{
  function confirm(uint index,bool confirmed);
}
contract UseExample is Confirmable{
  uint playCost=0.01 ether;
  uint tournamentDuration=1 days;
  uint tournamentStartTime;
  uint highestScore=0;
  address currentWinner=0x0;
  address ccAddress=0x0;
  CollateralCompute cVer;
  mapping(uint => GameOutcome) preComputedGames;
  uint cursor=0;

  struct GameOutcome{
    address user;
    uint finalScore;
  }

  modifier onlyCC(){
    require(msg.sender==ccAddress);
    _;
  }

  event PreComputedGame(string input,uint finalScore,address user);

  constructor(){
    cVer=CollateralCompute(ccAddress);
    tournamentStartTime=now;
  }
  function tournamentOver() public view returns(bool){
    return now>tournamentStartTime+tournamentDuration;
  }
  function declarePhysicsGameOutcome(string inputs,uint finalScore) public payable{
    require(msg.value>=playCost);
    require(!tournamentOver());
    emit PreComputedGame(inputs,finalScore,msg.sender);
    preComputedGames[cursor]=GameOutcome(msg.sender,finalScore);
    cVer.registerComputation.value(playCost/3)(cursor);
    cursor++;
  }
  function confirm(uint index,bool confirmed) onlyCC public{
    if(confirmed && preComputedGames[index].finalScore>highestScore){
      highestScore=preComputedGames[index].finalScore;
      currentWinner=preComputedGames[index].user;
    }
  }
  function finalizeTournament() public{
    require(tournamentOver());
    currentWinner.transfer(this.balance);
  }
}
