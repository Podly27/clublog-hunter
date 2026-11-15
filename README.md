# ClubLog Hunter

ClubLog Hunter is a native macOS app for hunting amateur radio DXpeditions with an Icom IC‑7300MK2. It puts Club Log Livestream frequencies and your worked band/mode combinations in one table. Click a supported frequency to tune the radio via CI‑V.

![ClubLog Hunter app icon](assets/icon.png)

## Screenshots

The Overview and CW tabs shown with sample data.

| Overview | CW memories |
| --- | --- |
| ![Overview with frequencies and worked slots](assets/overview.png) | ![CW tab with eight radio memories](assets/cw.png) |

## Build and launch

You'll need macOS, the Xcode Command Line Tools, and Python 3 at `/usr/bin/python3`. The app uses Swift, AppKit, WebKit, and the Python standard library.

```sh
./build.sh
open "build/ClubLog Hunter.app"
```

The build produces a locally signed app bundle.

## Set up the radio

1. In **Settings**, select the radio's serial device, baud rate and CI‑V address. The factory address for the IC‑7300MK2 is `B6`. The serial device name depends on the Mac and USB connection.
2. If WSJT‑X already uses the first virtual USB port, configure **USB (B) Function → CI‑V** on the radio and select the second port for Hunter. Disable **Enable Tx** in WSJT‑X before retuning from Hunter.
3. Click **Connect radio**. Hunter reconnects on launch using the saved settings. The indicator in the bottom right shows the connection state. **Simulation** lets you try the controls without hardware.

## Hunt expeditions

- Enter your callsign and a Club Log REST API token in **Settings**, then click **Save settings**. Create the token in Club Log under **Settings → API**. Hunter stores it in the macOS Keychain.
- The expedition menu loads callsigns from Club Log with a QSO in the last seven days. Hunter restores the last selected expedition when it is available. The manually configured callsigns are available at startup before the first successful fetch.
- **Overview** reads active band and mode combinations and their latest reported frequencies from the public Club Log Livestream. The app checks the page every five seconds. **Refresh live activity** checks immediately, and **Livestream web** opens the same page in your browser.
- Yellow cells show live activity with a reported frequency. Green cells show your worked slots and take precedence over yellow. Live frequencies disappear when the slot goes inactive or live data becomes unavailable. The livestream's recent contacts must include a frequency for the app to display it.
- Click a live or saved frequency to tune **VFO A**. Option-click a cell to edit or remove a saved frequency.
- In **Settings → Appearance**, select **Light**, **Dark**, or **System** to follow the macOS setting. Hunter remembers your choice.

## CW memories

Hunter loads M1–M8 after connecting. **Write** writes a memory and verifies it by reading it back. You can also save and reopen sets as JSON.

**TX** sends the text stored in the selected radio memory. It requires CW or CW‑R and Break-in. The CI‑V text command supports up to 30 characters. For longer messages or memories containing a contest-number placeholder `*`, send directly from the radio. **Stop CW** requests a stop.

## References

- [Icom IC‑7300MK2 CI‑V reference](https://icomuk.co.uk/files/icom/PDF/productAdditionalFile/IC-7300MK2_ENG_CI-V_0.pdf)
- [Club Log API reference](https://clublog.org/api/docs/index.php)

ClubLog Hunter is an independent project.
