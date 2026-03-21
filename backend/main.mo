import Liminal "mo:liminal";
import RouterMiddleware "mo:liminal/Middleware/Router";
import Router "mo:liminal/Router";
import IcpLedger "IcpLedger";
import UrlRouter "UrlRouter";
import UrlStore "UrlStore";
import BTree "mo:stableheapbtreemap/BTree";
import Principal "mo:core@1/Principal";
import Runtime "mo:core@1/Runtime";
import Result "mo:core@1/Result";

shared ({ caller = initializer }) persistent actor class Actor() = self {
  var urlStableData : UrlStore.StableData = {
    urls = BTree.init<Nat, UrlStore.Url>(null);
    nextId = 1;
  };

  transient var urlStore = UrlStore.Store(urlStableData);
  transient var urlRouter = UrlRouter.Router(urlStore);
  transient let canisterPrincipal = Principal.fromActor(self);

  system func preupgrade() {
    urlStableData := urlStore.toStableData();
  };

  system func postupgrade() {
    urlStore := UrlStore.Store(urlStableData);
    urlRouter := UrlRouter.Router(urlStore);
    routerConfig := buildRouterConfig();
    app := buildApp();
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

    switch (urlStore.validateCreateRequest(request)) {
      case (#err(message)) {
        return #err(message);
      };
      case (#ok(())) {};
    };

    switch (await IcpLedger.chargeForUrl(canisterPrincipal, caller)) {
      case (#err(message)) {
        #err("Payment required before Tiny ICP can create your short URL. " # message);
      };
      case (#ok(())) {
        switch (urlStore.create(request, caller)) {
          case (#ok(url)) #ok(urlStore.toView(url));
          case (#err(message)) #err(message);
        };
      };
    };
  };

  public shared ({ caller }) func delete_my_url(id : Nat) : async Result.Result<(), Text> {
    assertAuthenticated(caller);
    urlStore.delete(id, caller);
  };

  public shared ({ caller }) func withdraw_from_wallet(destinationAccountId : Text, amountE8s : Nat) : async Result.Result<(), Text> {
    assertAuthenticated(caller);
    await IcpLedger.withdrawFromWallet(canisterPrincipal, caller, destinationAccountId, amountE8s);
  };

  public shared query ({ caller }) func whoami() : async Principal {
    caller;
  };

  func assertAuthenticated(caller : Principal) {
    if (Principal.isAnonymous(caller)) {
      Runtime.trap("Authentication required");
    };
  };

  transient var routerConfig : RouterMiddleware.Config = buildRouterConfig();

  transient var app = buildApp();

  func buildRouterConfig() : RouterMiddleware.Config {
    {
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
  };

  func buildApp() : Liminal.App {
    Liminal.App({
      middleware = [RouterMiddleware.new(routerConfig)];
      errorSerializer = Liminal.defaultJsonErrorSerializer;
      candidRepresentationNegotiator = Liminal.defaultCandidRepresentationNegotiator;
      logger = Liminal.buildDebugLogger(#info);
    });
  };

  public query func http_request(request : Liminal.RawQueryHttpRequest) : async Liminal.RawQueryHttpResponse {
    app.http_request(request);
  };

  public func http_request_update(request : Liminal.RawUpdateHttpRequest) : async Liminal.RawUpdateHttpResponse {
    await* app.http_request_update(request);
  };
};
