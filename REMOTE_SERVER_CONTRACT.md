# Remote Server Contract

Hangar Express is provider-neutral. Server URLs are supplied only through the
ignored `Config/Local.xcconfig` file; no production host or infrastructure
configuration belongs in this repository.

All responses use HTTPS and `Content-Type: application/json` unless noted
otherwise. A successful response uses a `2xx` status. The Swift `Decodable`
models in the app are the source of truth for optional feed fields.

## Configured URL keys

`Config/AppConfiguration.xcconfig` exposes four empty build settings:

- `REMOTE_PRIMARY_BASE_URL`
- `REMOTE_FALLBACK_BASE_URL`
- `REMOTE_TRANSLATION_BASE_URL`
- `REMOTE_IP_REGION_URL`

Define their private values in `Config/Local.xcconfig`.

## Translation dictionary

`GET {translation-base}/item-translations/{locale}.json`

```json
{
  "locale": "zh-Hans",
  "version": 1,
  "generatedAt": "2026-01-01T00:00:00Z",
  "count": 1,
  "entries": [
    {
      "source": "Example Ship",
      "translation": "示例飞船",
      "kind": "ship",
      "aliases": []
    }
  ]
}
```

The response should include:

- `x-content-sha256`: lowercase SHA-256 of the exact response body
- `x-dictionary-version`: the JSON `version`
- `x-dictionary-entry-count`: the number of JSON `entries`
- `etag`: a non-empty entity tag

## Translation review submission

`POST {translation-base}/v1/translations/resolve`

The request body contains source and target locales, an optional dictionary
version, and at most 50 structured catalog terms. The response must preserve
each request item's `clientID` and `source` exactly:

```json
{
  "translations": [
    {
      "clientID": "ship-example",
      "source": "Example Ship",
      "status": "pending",
      "reason": null
    }
  ]
}
```

Supported statuses are `approved`, `pending`, `rejected`, `ineligible`, and
`unavailable`. The app never expects unreviewed translated text in this
response.

## Hosted data feeds

The primary and fallback base URLs may provide:

- `ships.json`: an object containing `ships`, with optional `manufacturers`,
  `storeUpgradeOffers`, and `generatedAt`
- `ship-details.json`: an object containing `ships`, with optional
  `manufacturers`
- `limited-ships.json`: either an array of sales or `{ "ships": [...] }`
- `events.json`: an `EventCalendarFeed` object with `schemaVersion: 1`, a
  matching `count`, and ISO-8601 dates

## IP region response

The configured region endpoint may return either JSON:

```json
{ "countryCode": "US" }
```

or UTF-8 key/value text containing a line such as `loc=US`. Country codes must
be two letters. Failures are non-fatal and leave the region unknown.
