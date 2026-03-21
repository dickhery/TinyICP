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
        case (?url) {
          let html = generateRedirectHtml(shortCode, url.originalUrl, url.metadata);
          routeContext.buildResponse(
            #ok,
            #custom({
              body = Text.encodeUtf8(html);
              headers = [
                ("Content-Type", "text/html; charset=utf-8"),
                ("Cache-Control", "no-cache, no-store, must-revalidate"),
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

      switch (store.create(createRequest, Principal.fromText("2vxsx-fae"), null)) {
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
      let urlKeys = ["id", "originalUrl", "shortCode", "clicks", "createdAt", "metadata"];
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

    func generateRedirectHtml(shortCode : Text, originalUrl : Text, metadata : ?UrlStore.UrlMetadata) : Text {
      let escapedOriginalUrl = escapeHtml(originalUrl);
      let title = switch (metadata) {
        case (?data) {
          switch (data.title) {
            case (?value) if (value != "") value;
            case _ "TinyICP Short Link - " # shortCode;
          };
        };
        case null "TinyICP Short Link - " # shortCode;
      };
      let description = switch (metadata) {
        case (?data) {
          switch (data.description) {
            case (?value) if (value != "") value;
            case _ "Shortened with TinyICP on the Internet Computer. Original: " # originalUrl;
          };
        };
        case null "Shortened with TinyICP on the Internet Computer. Original: " # originalUrl;
      };
      let siteName = switch (metadata) {
        case (?data) {
          switch (data.siteName) {
            case (?value) if (value != "") value;
            case _ "TinyICP";
          };
        };
        case null "TinyICP";
      };
      let canonicalUrl = switch (metadata) {
        case (?data) {
          switch (data.canonicalUrl) {
            case (?value) if (value != "") value;
            case _ originalUrl;
          };
        };
        case null originalUrl;
      };
      let escapedTitle = escapeHtml(title);
      let escapedDescription = escapeHtml(description);
      let escapedSiteName = escapeHtml(siteName);
      let escapedCanonicalUrl = escapeHtml(canonicalUrl);
      let imageMeta = switch (metadata) {
        case (?data) {
          switch (data.imageUrl) {
            case (?value) if (value != "") {
              let escapedImageUrl = escapeHtml(value);
              "    <meta property=\"og:image\" content=\"" # escapedImageUrl # "\">\n" #
              "    <meta name=\"twitter:image\" content=\"" # escapedImageUrl # "\">\n";
            };
            case _ "";
          };
        };
        case null "";
      };

      "<!DOCTYPE html>\n" #
      "<html lang=\"en\">\n" #
      "<head>\n" #
      "    <meta charset=\"UTF-8\">\n" #
      "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n" #
      "    <title>" # escapedTitle # "</title>\n" #
      "    <meta property=\"og:type\" content=\"website\">\n" #
      "    <meta property=\"og:url\" content=\"" # escapedCanonicalUrl # "\">\n" #
      "    <meta property=\"og:title\" content=\"" # escapedTitle # "\">\n" #
      "    <meta property=\"og:description\" content=\"" # escapedDescription # "\">\n" #
      "    <meta property=\"og:site_name\" content=\"" # escapedSiteName # "\">\n" #
      imageMeta #
      "    <meta name=\"twitter:card\" content=\"summary_large_image\">\n" #
      "    <meta name=\"twitter:title\" content=\"" # escapedTitle # "\">\n" #
      "    <meta name=\"twitter:description\" content=\"" # escapedDescription # "\">\n" #
      "    <meta http-equiv=\"refresh\" content=\"0; url=" # escapedOriginalUrl # "\">\n" #
      "    <style>\n" #
      "      body { font-family: monospace; background: #000; color: #00ff9c; padding: 40px; text-align: center; font-size: 18px; }\n" #
      "      .panel { max-width: 640px; margin: 10vh auto; border: 1px solid #00ff9c; padding: 32px; box-shadow: 0 0 24px rgba(0, 255, 156, 0.15); background: rgba(0,0,0,0.92); }\n" #
      "      a { color: #8fffd2; }\n" #
      "      .muted { opacity: 0.75; font-size: 14px; word-break: break-all; }\n" #
      "    </style>\n" #
      "</head>\n" #
      "<body>\n" #
      "    <div class=\"panel\">\n" #
      "      <h1>🌐 TinyICP</h1>\n" #
      "      <p>Redirecting you to the original URL...</p>\n" #
      "      <p class=\"muted\">" # escapedOriginalUrl # "</p>\n" #
      "      <p>If you are not redirected automatically, <a href=\"" # escapedOriginalUrl # "\">click here</a>.</p>\n" #
      "    </div>\n" #
      "    <script>setTimeout(() => { window.location.replace('" # escapeJsString(originalUrl) # "'); }, 300);</script>\n" #
      "</body>\n" #
      "</html>";
    };

    func escapeHtml(value : Text) : Text {
      value
      |> Text.replace(_, #text("&"), "&amp;")
      |> Text.replace(_, #text("\""), "&quot;")
      |> Text.replace(_, #text("'"), "&#39;")
      |> Text.replace(_, #text("<"), "&lt;")
      |> Text.replace(_, #text(">"), "&gt;");
    };

    func escapeJsString(value : Text) : Text {
      value
      |> Text.replace(_, #text("\\"), "\\\\")
      |> Text.replace(_, #text("'"), "\\'")
      |> Text.replace(_, #text("\n"), "\\n")
      |> Text.replace(_, #text("\r"), "\\r");
    };
  };
};
