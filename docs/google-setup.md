# Connecting Google Health (bring your own client)

PulseBar reads your Fitbit / Google wearable history through the official
[Google Health API](https://developers.google.com/health). To keep PulseBar free
and avoid Google's 100-user cap on shared unverified apps, **you create your own
free Google OAuth client**. It takes about five minutes and you only do it once.

1. Install the **Google Health** app on your phone and sign in with the Google account you'll use.
   Google requires this before any app can read your data.
2. [Create a Google Cloud project](https://console.cloud.google.com/projectcreate).
3. [Enable the Google Health API](https://console.developers.google.com/apis/library/health.googleapis.com) in it.
4. [OAuth consent screen → Audience](https://console.developers.google.com/auth/audience):
   User type **External**, publishing status **Testing**. Under **Test users**, add your own email.
5. [Data Access](https://console.developers.google.com/auth/scopes) → *Add or remove scopes* → add exactly these read-only scopes:
   - `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly`
   - `https://www.googleapis.com/auth/googlehealth.sleep.readonly`
   - `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`
6. [Credentials](https://console.developers.google.com/apis/credentials) → *Create credentials* → *OAuth client ID* →
   Application type **Desktop app**. Copy the **Client ID** and **Client secret**.
7. In PulseBar: **Settings → Google**, paste both, read what PulseBar will access, tick *I understand and agree*,
   and click **Connect Google**. Your browser opens Google's sign-in; approve, then return to PulseBar.

PulseBar then downloads the last 90 days and keeps syncing on launch, on wake and every 3 hours.

## Things to know

- **Weekly re-login in Testing mode.** Google expires sign-ins for projects in *Testing* after 7 days
  ([source](https://developers.google.com/health/setup)). PulseBar shows **Reconnect Google**; nothing is lost.
- **How it signs in.** OAuth 2.0 authorization code with PKCE, redirected to `http://127.0.0.1:<random port>/`
  in your default browser, as Google recommends for desktop apps. The refresh token is stored in your macOS Keychain.
- **Read-only.** PulseBar never writes to Google Health.
- **Disconnect.** Settings → Google → Disconnect revokes the token at Google and deletes it from the Keychain.
