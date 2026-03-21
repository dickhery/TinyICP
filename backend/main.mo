import Liminal "mo:liminal";
import RouterMiddleware "mo:liminal/Middleware/Router";
import Router "mo:liminal/Router";
import IcpLedger "IcpLedger";
import UrlRouter "UrlRouter";
import UrlStore "UrlStore";
import BTree "mo:stableheapbtreemap/BTree";
import Nat64 "mo:core@1/Nat64";
import Principal "mo:core@1/Principal";
import Result "mo:core@1/Result";
import Runtime "mo:core@1/Runtime";

shared ({ caller = initializer }) persistent actor class Actor() = self {
  var urlStableData : UrlStore.StableData = {
    urls = BTree.init<Nat, UrlStore.Url>(null);
    nextId = 1;
  };

  transient var urlStore = UrlStore.Store(urlStableData);
  transient let urlRouter = UrlRouter.Router(urlStore);
  transient let canisterPrincipal = Principal.fromActor(self);

  system func preupgrade() {
    urlStableData := urlStore.toStableData();
  };

  system func postupgrade() {
    urlStore := UrlStore.Store(urlStableData);
  };

  public shared query ({ caller }) func list_my_urls() : async [UrlStore.UrlView] {
    assertAuthenticated(caller);
    urlStore.getUrlsByOwner(caller);
  };

  public shared ({ caller }) func get_wallet_info() : async IcpLedger.WalletInfo {
    assertAuthenticated(caller);
    await IcpLedger.getWalletInfo(canisterPrincipal, caller);
  };

  public shared ({ caller }) func create_my_url(request : UrlStore.CreateRequest) : async Result.Result<UrlStore.UrlView, Text> {
    assertAuthenticated(caller);

    let pendingUrl = switch (urlStore.createPending(request, caller)) {
      case (#ok(url)) url;
      case (#err(message)) return #err(message);
    };

    let paymentResult = await IcpLedger.transferFromSubaccount({
      fromSubaccount = IcpLedger.subaccountForPrincipal(caller);
      to = switch (IcpLedger.fromHex(IcpLedger.treasuryAccountIdHex)) {
        case (#ok(account)) account;
        case (#err(message)) return #err(message);
      };
      amountE8s = IcpLedger.tinyUrlPriceE8s;
      memo = Nat64.fromNat(pendingUrl.id);
    });

    switch (paymentResult) {
      case (#err(message)) {
        ignore urlStore.deletePending(pendingUrl.id, caller);
        #err("Unable to collect the 1.0 ICP shortening fee. " # message # " Your Tiny URL was not created.");
      };
      case (#ok(_)) {
        switch (urlStore.markPaid(pendingUrl.id, caller)) {
          case (#ok(url)) #ok(urlStore.toView(url));
          case (#err(message)) #err(message);
        };
      };
    };
  };

  public shared ({ caller }) func transfer_from_wallet(destination : Text, amountE8s : Nat) : async Result.Result<Nat64, Text> {
    assertAuthenticated(caller);

    if (amountE8s == 0) {
      return #err("Transfer amount must be greater than zero.");
    };

    let destinationAccount = switch (IcpLedger.destinationToAccountIdentifier(destination)) {
      case (#ok(account)) account;
      case (#err(message)) return #err(message);
    };

    await IcpLedger.transferFromSubaccount({
      fromSubaccount = IcpLedger.subaccountForPrincipal(caller);
      to = destinationAccount;
      amountE8s;
      memo = 0;
    });
  };

  public shared ({ caller }) func delete_my_url(id : Nat) : async Result.Result<(), Text> {
    assertAuthenticated(caller);
    urlStore.delete(id, caller);
  };

  public shared query ({ caller }) func whoami() : async Principal {
    caller;
  };

  func assertAuthenticated(caller : Principal) {
    if (Principal.isAnonymous(caller)) {
      Runtime.trap("Authentication required");
    };
  };

  transient let routerConfig : RouterMiddleware.Config = {
    prefix = null;
    identityRequirement = null;
    routes = [
      Router.getQuery("/urls", urlRouter.getAllUrls),
      Router.postUpdate("/shorten", urlRouter.createShortUrl),
      Router.deleteUpdate("/urls/{id}", urlRouter.deleteUrl),
      Router.getUpdate("/s/{shortCode}", urlRouter.redirect),
      Router.getQuery("/s/{shortCode}/stats", urlRouter.getStats),
    ];
  };

  transient let app = Liminal.App({
    middleware = [RouterMiddleware.new(routerConfig)];
    errorSerializer = Liminal.defaultJsonErrorSerializer;
    candidRepresentationNegotiator = Liminal.defaultCandidRepresentationNegotiator;
    logger = Liminal.buildDebugLogger(#info);
  });

  public query func http_request(request : Liminal.RawQueryHttpRequest) : async Liminal.RawQueryHttpResponse {
    app.http_request(request);
  };

  public func http_request_update(request : Liminal.RawUpdateHttpRequest) : async Liminal.RawUpdateHttpResponse {
    await* app.http_request_update(request);
  };
};
