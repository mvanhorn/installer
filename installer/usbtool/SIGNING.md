# Signing June USB

Unsigned builds work. Windows shows "Windows protected your PC" (More info →
Run anyway), and macOS makes users allow the app in System Settings →
Privacy & Security. Signed builds open normally.

`.github/workflows/june-usb.yml` builds every `usb-v*` tag unsigned. A
**signed** release is a manual run of the workflow on `main` (see
[Releasing](#releasing)); it signs when the secrets below exist.

## Windows: Azure Artifact Signing

Artifact Signing (formerly Trusted Signing) takes individual developers in
the US and Canada. The Basic tier is billed monthly. Signatures carry a
timestamp, so released files stay valid after you stop paying.

### One-time setup (Azure portal)

1. **Azure account**: <https://portal.azure.com>, with a pay-as-you-go
   subscription. Under *Cost Management + Billing → Billing profiles /
   accounts*, check that the account type is **Individual** and that the
   legal name and sold-to address match your driver's license or passport
   exactly. Identity validation copies them from there, and they appear on
   the certificate (city, state and country; street only if you opt in).
2. **Register the provider**: *Subscriptions → your subscription → Resource
   providers → `Microsoft.CodeSigning` → Register*.
3. **Create the account**: search *Artifact Signing Accounts → Create*.
   - Resource group: new, e.g. `june-signing`
   - Account name: globally unique, 3–24 letters and digits, e.g. `projectjulysign`
   - Region: e.g. *East US* (endpoint `https://eus.codesigning.azure.net`)
   - Pricing: **Basic**
4. **Give yourself the verifier role**: in the new account, *Access control
   (IAM) → Add role assignment → **Artifact Signing Identity Verifier** →
   your user*.
5. **Validate your identity**: in the account, *Objects → Identity
   validations → Individual → New identity → Public*. Pick the billing
   account; the form fills itself. Create it, wait for **Action Required**,
   open the request and follow the link. You verify with AU10TIX (photo of
   your ID, a selfie on your phone) and add the resulting Verified ID to
   Microsoft Authenticator. The status changes to **Completed**, usually
   within 1–3 business days.
6. **Certificate profile**: *Objects → Certificate profiles → Create →
   **Public Trust***. Name e.g. `juneusb`; under *Verified CN and O* pick
   your validation.

### Connect GitHub (OIDC, no stored passwords)

7. *Microsoft Entra ID → App registrations → New registration*: name
   `june-usb-github`, single tenant. Note the **Application (client) ID**
   and **Directory (tenant) ID**.
8. In that app: *Certificates & secrets → Federated credentials → Add →
   GitHub Actions deploying Azure resources*. Organization `prj-july`,
   repository `installer`, entity **Branch**, branch `main`, name e.g.
   `installer-main`. This lets workflow runs on `main` (and nothing else) sign.
   (Private repos on GitHub Free have no environments, and federated
   credentials can't match tag patterns, so signing runs from `main`.)
9. In the signing account: *Access control (IAM) → Add role assignment →
   **Artifact Signing Certificate Profile Signer** → the app
   `june-usb-github`*.
10. In GitHub, *prj-july/installer → Settings → Secrets and variables →
    Actions*:
    - Secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
    - Variables: `AZURE_SIGNING_ENDPOINT` (e.g.
      `https://eus.codesigning.azure.net/`), `AZURE_SIGNING_ACCOUNT`
      (`projectjulysign`), `AZURE_SIGNING_PROFILE` (`juneusb`)

### Pay only when releasing

To stop paying between releases, **delete the Artifact Signing account**
(not the subscription). Already-signed files stay valid because they are
timestamped. Your identity validation is kept, since it belongs to the
subscription. For the next release, repeat steps 3, 4 (new account), 6
(new profile, same validation) and 9, and update the variables if the
names changed.

## macOS: Developer ID and notarization

The Apple Developer Program membership you already have for the iPhone app
covers this; nothing extra to buy. Only the **Account Holder** can create
Developer ID certificates.

1. **Certificate**: <https://developer.apple.com/account/resources/certificates>
   → **+** → *Developer ID Application*. It asks for a certificate signing
   request; without a Mac, make one with OpenSSL:
   ```sh
   openssl req -new -newkey rsa:2048 -nodes -keyout devid.key -out devid.csr -subj "/emailAddress=YOU/CN=YOUR NAME/C=US"
   ```
   Download `developerID_application.cer`, then bundle it:
   ```sh
   openssl x509 -inform DER -in developerID_application.cer -out devid.pem
   openssl pkcs12 -export -legacy -inkey devid.key -in devid.pem -out devid.p12
   ```
   Keep `devid.key` and `devid.p12` out of the repository and off shared machines.
2. **API key for notarization**: <https://appstoreconnect.apple.com/access/integrations/api>
   → *Team Keys → +*, role **Developer**. Download the `.p8` (only possible
   once) and note the **Key ID** and **Issuer ID**.
3. GitHub secrets:
   - `MAC_CERT_P12_BASE64`: `base64 -w0 devid.p12` (PowerShell:
     `[Convert]::ToBase64String([IO.File]::ReadAllBytes("devid.p12"))`)
   - `MAC_CERT_PASSWORD`: the export password from step 1
   - `MAC_SIGNING_IDENTITY`: `Developer ID Application: YOUR NAME (TEAMID)`
   - `APPLE_API_KEY_P8_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`

Notarized apps keep opening after the membership lapses; you only need an
active membership to sign new releases.

## Releasing

1. Tag the commit and push the tag. This builds it unsigned, as a check:
   ```sh
   git tag -a usb-v0.1.2 -m "June USB 0.1.2" && git push origin usb-v0.1.2
   ```
2. On GitHub: *Actions → June USB → Run workflow*, branch **main**, tag
   `usb-v0.1.2`. This builds that tag, signs it and attaches `June-USB.exe`,
   `June-USB.dmg` and `SHA256SUMS` to a **draft** GitHub release.
   (`gh workflow run june-usb.yml -R prj-july/installer -f tag=usb-v0.1.2`
   does the same.)
3. Check the draft, download the three files, then put them on the download
   site, where the website links them:
   ```sh
   ./publish_usbtool.sh usb-v0.1.2 ~/Downloads/june-usb-release
   ```
   That uploads `june-usb/usb-v0.1.2/…` (kept) and replaces
   `https://downloads.project-july.org/june-usb/June-USB.exe` and `.dmg`.
