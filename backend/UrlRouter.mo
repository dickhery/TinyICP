import Array "mo:core@1/Array";
import Blob "mo:core@1/Blob";
import Route "mo:liminal/Route";
import Nat "mo:core@1/Nat";
import Debug "mo:core@1/Debug";
import UrlStore "UrlStore";
import Serializer "Serializer";
import Serde "mo:serde";
import RouteContext "mo:liminal/RouteContext";
import Text "mo:core@1/Text";
import Iter "mo:core@1/Iter";
import UrlKit "mo:url-kit@3";
import Runtime "mo:core@1/Runtime";
import Principal "mo:core@1/Principal";

module {

  public class Router(
    store : UrlStore.Store
  ) = self {

    public func getAllUrls(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let urls = Array.map<UrlStore.Url, UrlStore.UrlView>(store.getAllUrls(), store.toView);
      routeContext.buildResponse(#ok, #content(toCandid(to_candid (urls))));
    };

    public func redirect<system>(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let shortCode = routeContext.getRouteParam("shortCode");

      switch (store.incrementClicks(shortCode)) {
        case (null) {
          routeContext.buildResponse(#notFound, #error(#message("Short URL not found")));
        };
        case (?originalUrl) {
          routeContext.buildResponse(
            #found,
            #custom({
              body = Text.encodeUtf8("Redirecting to " # originalUrl);
              headers = [
                ("Location", originalUrl),
                ("Cache-Control", "no-cache"),
              ];
            }),
          );
        };
      };
    };

    public func getStats(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let shortCode = routeContext.getRouteParam("shortCode");

      switch (store.getUrlByShortCode(shortCode)) {
        case (null) {
          routeContext.buildResponse(#notFound, #error(#message("Short URL not found")));
        };
        case (?url) {
          routeContext.buildResponse(#ok, #content(toCandid(to_candid (store.toView(url)))));
        };
      };
    };

    public func createShortUrl<system>(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      Debug.print("Creating short URL...");
      let contentType = routeContext.httpContext.getHeader("content-type");

      let createRequest : UrlStore.CreateRequest = switch (contentType) {
        case (?"application/x-www-form-urlencoded") {
          parseFormData(routeContext);
        };
        case (?"text/plain") {
          let ?body : ?Text = routeContext.parseUtf8Body() else Runtime.trap("Failed to decode request body as UTF-8");
          { originalUrl = body; customSlug = null };
        };
        case _ {
          switch (routeContext.parseJsonBody<UrlStore.CreateRequest>(Serializer.deserializeCreateRequest)) {
            case (#err(e)) return routeContext.buildResponse(#badRequest, #error(#message("Failed to parse request. Error: " # e)));
            case (#ok(req)) req;
          };
        };
      };

      switch (store.create(createRequest, Principal.fromText("2vxsx-fae"))) {
        case (#err(errorMessage)) {
          routeContext.buildResponse(#badRequest, #error(#message(errorMessage)));
        };
        case (#ok(url)) {
          routeContext.buildResponse(#created, #content(toCandid(to_candid (store.toView(url)))));
        };
      };
    };

    public func deleteUrl<system>(routeContext : RouteContext.RouteContext) : Route.HttpResponse {
      let idText = routeContext.getRouteParam("id");
      let ?id = Nat.fromText(idText) else return routeContext.buildResponse(#badRequest, #error(#message("Invalid id '" # idText # "', must be a positive integer")));

      switch (store.delete(id, Principal.fromText("2vxsx-fae"))) {
        case (#ok()) routeContext.buildResponse(#noContent, #empty);
        case (#err(message)) {
          if (message == "URL not found") {
            routeContext.buildResponse(#notFound, #error(#message(message)));
          } else {
            routeContext.buildResponse(#forbidden, #error(#message(message)));
          };
        };
      };
    };

    private func parseFormData(routeContext : RouteContext.RouteContext) : UrlStore.CreateRequest {
      let ?body : ?Text = routeContext.parseUtf8Body() else Runtime.trap("Failed to decode request body as UTF-8");
      var originalUrl = "";
      var customSlug : ?Text = null;

      let pairs = Text.split(body, #char('&'));
      for (pair in pairs) {
        let keyValue = Text.split(pair, #char('='));
        let keyValueArray = Iter.toArray(keyValue);
        if (keyValueArray.size() == 2) {
          let key = switch (UrlKit.decodeText(keyValueArray[0])) {
            case (#ok(decoded)) decoded;
            case (#err(e)) Runtime.trap("Failed to decode key: " # e);
          };
          let value = switch (UrlKit.decodeText(keyValueArray[1])) {
            case (#ok(decoded)) decoded;
            case (#err(e)) Runtime.trap("Failed to decode value: " # e);
          };

          if (key == "url") {
            originalUrl := value;
          } else if (key == "slug") {
            customSlug := ?value;
          };
        };
      };

      { originalUrl = originalUrl; customSlug = customSlug };
    };

    func toCandid(value : Blob) : Serde.Candid.Candid {
      let urlKeys = ["id", "originalUrl", "shortCode", "clicks", "createdAt"];
      let options : ?Serde.Options = ?{
        renameKeys = [];
        blob_contains_only_values = false;
        types = null;
        use_icrc_3_value_type = false;
      };
      switch (Serde.Candid.decode(value, urlKeys, options)) {
        case (#err(e)) {
          Debug.print("Failed to decode URL Candid. Error: " # e);
          Runtime.trap("Failed to decode URL Candid. Error: " # e);
        };
        case (#ok(candid)) {
          if (candid.size() != 1) {
            Debug.print("Invalid Candid response. Expected 1 element, got " # Nat.toText(candid.size()));
            Runtime.trap("Invalid Candid response. Expected 1 element, got " # Nat.toText(candid.size()));
          };
          candid[0];
        };
      };
    };
  };
};
