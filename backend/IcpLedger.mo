import Array "mo:core@1/Array";
import Blob "mo:core@1/Blob";
import Char "mo:core@1/Char";
import Iter "mo:core@1/Iter";
import Nat "mo:core@1/Nat";
import Nat8 "mo:core@1/Nat8";
import Nat64 "mo:core@1/Nat64";
import Principal "mo:core@1/Principal";
import Result "mo:core@1/Result";
import Text "mo:core@1/Text";
import VarArray "mo:core@1/VarArray";

module {
  public let ledger : Ledger = actor ("ryjl3-tyaaa-aaaaa-aaaba-cai");
  public let transferFeeE8s : Nat = 10_000;
  public let tinyUrlPriceE8s : Nat = 100_000_000;

  public type Tokens = { e8s : Nat64 };
  public type AccountBalanceArgs = { account : Text };
  public type Memo = Nat64;
  public type Timestamp = { timestamp_nanos : Nat64 };
  public type TransferArgs = {
    memo : Memo;
    amount : Tokens;
    fee : Tokens;
    from_subaccount : ?Blob;
    to : Blob;
    created_at_time : ?Timestamp;
  };
  public type TransferError = {#TxTooOld : { allowed_window_nanos : Nat64 }; #BadFee : { expected_fee : Tokens }; #TxDuplicate : { duplicate_of : Nat64 }; #TxCreatedInFuture; #InsufficientFunds : { balance : Tokens }};
  public type TransferResult = {#Ok : Nat64; #Err : TransferError};
  public type Ledger = actor {
    account_balance_dfx : shared query AccountBalanceArgs -> async Tokens;
    transfer : shared TransferArgs -> async TransferResult;
  };
  public type WalletInfo = {
    canisterPrincipal : Principal;
    depositAccountId : Text;
    subaccountHex : Text;
    balanceE8s : Nat;
    transferFeeE8s : Nat;
    tinyUrlPriceE8s : Nat;
  };

  public func subaccountForPrincipal(user : Principal) : Blob {
    let principalBytes = Blob.toArray(Principal.toBlob(user));
    let output = VarArray.tabulate<Nat8>(32, func _ = 0);
    output[0] := Nat8.fromNat(principalBytes.size());

    for (i in principalBytes.keys()) {
      if (i + 1 < 32) {
        output[i + 1] := principalBytes[i];
      };
    };

    Blob.fromVarArray(output);
  };

  public func accountIdForUser(canisterPrincipal : Principal, user : Principal) : Blob {
    Principal.toLedgerAccount(canisterPrincipal, ?subaccountForPrincipal(user));
  };

  public func toHex(blob : Blob) : Text {
    let parts = Array.map<Nat8, Text>(Blob.toArray(blob), byteToHex);
    Text.join("", parts.values());
  };

  public func getWalletInfo(canisterPrincipal : Principal, user : Principal) : async WalletInfo {
    let account = accountIdForUser(canisterPrincipal, user);
    let depositAccountId = toHex(account);
    let balance = await ledger.account_balance_dfx({ account = depositAccountId });
    {
      canisterPrincipal;
      depositAccountId;
      subaccountHex = toHex(subaccountForPrincipal(user));
      balanceE8s = Nat64.toNat(balance.e8s);
      transferFeeE8s;
      tinyUrlPriceE8s;
    };
  };

  public func accountIdFromHex(accountId : Text) : ?Blob {
    if (accountId.size() != 64) {
      return null;
    };

    let bytes = VarArray.tabulate<Nat8>(32, func _ = 0);
    let chars = accountId.chars() |> Iter.toArray(_);
    var i = 0;

    while (i < 32) {
      let ?high = hexCharToNat8(chars[i * 2]) else return null;
      let ?low = hexCharToNat8(chars[i * 2 + 1]) else return null;
      bytes[i] := high * 16 + low;
      i += 1;
    };

    ?Blob.fromVarArray(bytes);
  };

  public func transferIcp(fromSubaccount : ?Blob, to : Blob, amountE8s : Nat) : async Result.Result<Nat64, Text> {
    let transferResult = await ledger.transfer({
      memo = 0;
      amount = { e8s = Nat64.fromNat(amountE8s) };
      fee = { e8s = Nat64.fromNat(transferFeeE8s) };
      from_subaccount = fromSubaccount;
      to;
      created_at_time = null;
    });

    switch (transferResult) {
      case (#Ok(blockIndex)) #ok(blockIndex);
      case (#Err(transferError)) #err(debug_show (transferError));
    };
  };

  func hexCharToNat8(char : Char) : ?Nat8 {
    switch (char) {
      case ('0') ?0;
      case ('1') ?1;
      case ('2') ?2;
      case ('3') ?3;
      case ('4') ?4;
      case ('5') ?5;
      case ('6') ?6;
      case ('7') ?7;
      case ('8') ?8;
      case ('9') ?9;
      case ('a') or ('A') ?10;
      case ('b') or ('B') ?11;
      case ('c') or ('C') ?12;
      case ('d') or ('D') ?13;
      case ('e') or ('E') ?14;
      case ('f') or ('F') ?15;
      case _ null;
    };
  };

  func byteToHex(byte : Nat8) : Text {
    let symbols = [
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
    ];
    let value = Nat8.toNat(byte);
    symbols[value / 16] # symbols[value % 16];
  };
};
