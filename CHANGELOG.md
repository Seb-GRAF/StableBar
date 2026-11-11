# Changelog

## [0.13.0](https://github.com/Seb-GRAF/StableBar/compare/v0.12.0...v0.13.0) (2026-11-11)

### Features

* answer common questions and send feedback from a Help section ([#564](https://github.com/Seb-GRAF/StableBar/issues/564)) ([325083e](https://github.com/Seb-GRAF/StableBar/commit/325083e746547fed3bfea8b6a9b84548a4c5e334))
* apply migrations to includes, packages and every screen setup's bar ([#539](https://github.com/Seb-GRAF/StableBar/issues/539)) ([6cc59f4](https://github.com/Seb-GRAF/StableBar/commit/6cc59f4b2b6a7fcf2319815b12541d5e8a451e74))
* check in setup that Workspaces can reach yabai or OmniWM ([#552](https://github.com/Seb-GRAF/StableBar/issues/552)) ([3a9ef7e](https://github.com/Seb-GRAF/StableBar/commit/3a9ef7ec1460750c5aa93d139bfc2379d047a9a7)), closes [#463](https://github.com/Seb-GRAF/StableBar/issues/463)
* check the Switch to Desktop shortcuts in setup and Settings ([#551](https://github.com/Seb-GRAF/StableBar/issues/551)) ([92c11e1](https://github.com/Seb-GRAF/StableBar/commit/92c11e153c736fb252571657ce1a21eed9ab56d4)), closes [#447](https://github.com/Seb-GRAF/StableBar/issues/447)
* follow Reduce Transparency and Increase Contrast ([#542](https://github.com/Seb-GRAF/StableBar/issues/542)) ([3ea111b](https://github.com/Seb-GRAF/StableBar/commit/3ea111bf6c1a76e2e6963053dab83c93e758675a))
* guide Accessibility access with a panel to drag StableBar into System Settings ([#559](https://github.com/Seb-GRAF/StableBar/issues/559)) ([29f000c](https://github.com/Seb-GRAF/StableBar/commit/29f000cd2b0ff3438df416670fe6395a36662a2f))
* pause scripts and providers while the displays sleep or the screen is locked ([#538](https://github.com/Seb-GRAF/StableBar/issues/538)) ([a09513d](https://github.com/Seb-GRAF/StableBar/commit/a09513d4ba4c07bd59a8866376009878a4db0441))
* sign updates with an EdDSA key as well as the Developer ID ([#540](https://github.com/Seb-GRAF/StableBar/issues/540)) ([7e34d56](https://github.com/Seb-GRAF/StableBar/commit/7e34d56d9d0071304970e664aaa325bd97da90d6))
* turn on Keep windows clear in setup when no window manager runs ([#553](https://github.com/Seb-GRAF/StableBar/issues/553)) ([a80b001](https://github.com/Seb-GRAF/StableBar/commit/a80b001936bfd1cc56cc567989f1dff5727b9ddd)), closes [#466](https://github.com/Seb-GRAF/StableBar/issues/466) [#439](https://github.com/Seb-GRAF/StableBar/issues/439)

### Bug Fixes

* follow Reduce Motion in setup's steps, theme row and tiles ([9c3f0c4](https://github.com/Seb-GRAF/StableBar/commit/9c3f0c440f45d3bb7cdc3cf74776073d00c7265e)), closes [#465](https://github.com/Seb-GRAF/StableBar/issues/465)
* install packages when the configuration folder is a symbolic link ([#531](https://github.com/Seb-GRAF/StableBar/issues/531)) ([7e4f88b](https://github.com/Seb-GRAF/StableBar/commit/7e4f88b28fc880404f8b9ec9b54c2f33951b95a2)), closes [#530](https://github.com/Seb-GRAF/StableBar/issues/530)
* keep setup's later choices when the preset changes ([3318ae0](https://github.com/Seb-GRAF/StableBar/commit/3318ae023833967fc6c8a084d32107c5a479f2eb)), closes [#461](https://github.com/Seb-GRAF/StableBar/issues/461)
* keep the website's Store review sheet inside its window ([9519645](https://github.com/Seb-GRAF/StableBar/commit/9519645bd505051766e4de87fba500c747848a44)), closes [#526](https://github.com/Seb-GRAF/StableBar/issues/526)
* leave windows alone until setup finishes ([#547](https://github.com/Seb-GRAF/StableBar/issues/547)) ([c9b75cf](https://github.com/Seb-GRAF/StableBar/commit/c9b75cf803fac061ac313256d6674601b7df5540)), closes [#466](https://github.com/Seb-GRAF/StableBar/issues/466)
* let a group wider than its tray scroll sideways while editing the bar in place ([#543](https://github.com/Seb-GRAF/StableBar/issues/543)) ([f6e6e25](https://github.com/Seb-GRAF/StableBar/commit/f6e6e257711b95f3e21aa49b758977509695df1f))
* make setup's tiles, closing card and permission buttons work with the keyboard and VoiceOver ([#554](https://github.com/Seb-GRAF/StableBar/issues/554)) ([0944100](https://github.com/Seb-GRAF/StableBar/commit/094410067df7d46d7794958784c960abc2f4f889)), closes [#464](https://github.com/Seb-GRAF/StableBar/issues/464)
* offer Keep notifications clear only on macOS 26 and later ([#550](https://github.com/Seb-GRAF/StableBar/issues/550)) ([5fd428a](https://github.com/Seb-GRAF/StableBar/commit/5fd428a158d263a1d9b4ca0e8ddd741704066a4f)), closes [#458](https://github.com/Seb-GRAF/StableBar/issues/458)
* offer the Notch preset only on Macs with a notch ([#548](https://github.com/Seb-GRAF/StableBar/issues/548)) ([3fef60f](https://github.com/Seb-GRAF/StableBar/commit/3fef60f2a7842b3001ef7ee88453ea4f8cba60be)), closes [#457](https://github.com/Seb-GRAF/StableBar/issues/457)
* open an app's own menu when Menu bar items can't draw its rows ([#541](https://github.com/Seb-GRAF/StableBar/issues/541)) ([24f16d7](https://github.com/Seb-GRAF/StableBar/commit/24f16d7cf5f2f7f266b635399b1f9fb977242743))
* shorten long errors in the bar's menus and open Status from them ([#536](https://github.com/Seb-GRAF/StableBar/issues/536)) ([5710a3e](https://github.com/Seb-GRAF/StableBar/commit/5710a3e4ab44ff15b17d6f7afcc703e64633bc3e))

## [0.12.0](https://github.com/Seb-GRAF/StableBar/compare/v0.11.0...v0.12.0) (2026-11-10)

### Features

* ask for the permissions your bar needs before setup uses them ([#442](https://github.com/Seb-GRAF/StableBar/issues/442)) ([9494cc7](https://github.com/Seb-GRAF/StableBar/commit/9494cc7a6dd7aa4e1cb5304c9f041e4d3ec3be5e)), closes [#441](https://github.com/Seb-GRAF/StableBar/issues/441)
* let a group's top corners curve outward into the top of the screen ([265eb90](https://github.com/Seb-GRAF/StableBar/commit/265eb908e48e31c573bb493b0a9fab8571ae0e74))
* paint the notch black so screen shares and screenshots match the display ([c40dda3](https://github.com/Seb-GRAF/StableBar/commit/c40dda344c2a1a0654db824f25f2a5ed9996fc89))
* set widget, popup and tooltip backgrounds separately ([7eaf5af](https://github.com/Seb-GRAF/StableBar/commit/7eaf5af2ec3d0688766cba554132c86b747535a5))
* show Rift workspaces in workspace widgets ([d0f6d4d](https://github.com/Seb-GRAF/StableBar/commit/d0f6d4d919688e8413b77f14d83f869821b53efc))
* turn on Open at login when setup replaces the menu bar ([#507](https://github.com/Seb-GRAF/StableBar/issues/507)) ([d24abe1](https://github.com/Seb-GRAF/StableBar/commit/d24abe1ebccb324235713785b999eea6cd3caa9c))

### Bug Fixes

* ask before Skip setup throws away the choices made so far ([#470](https://github.com/Seb-GRAF/StableBar/issues/470)) ([66f47ea](https://github.com/Seb-GRAF/StableBar/commit/66f47ea12336531cb63afbcf893f26c8a4a7a233)), closes [#454](https://github.com/Seb-GRAF/StableBar/issues/454)
* ask where the bar goes first, and for permissions after the choices ([#492](https://github.com/Seb-GRAF/StableBar/issues/492)) ([1f45416](https://github.com/Seb-GRAF/StableBar/commit/1f454161ff12ef9bf49c03c2c5a6821080d7c675)), closes [#450](https://github.com/Seb-GRAF/StableBar/issues/450)
* drop a window that left every workspace when clicking it fails ([ec45fcc](https://github.com/Seb-GRAF/StableBar/commit/ec45fcc1b567aa86dbc4232091b3e707befb7cfd)), closes [#520](https://github.com/Seb-GRAF/StableBar/issues/520)
* drop stray focus rings and show popup focus in the theme's hover look ([61ea306](https://github.com/Seb-GRAF/StableBar/commit/61ea306bc647e21c80a8a3570873640b0909fc54))
* fall back to macOS Spaces when no window manager is running ([#436](https://github.com/Seb-GRAF/StableBar/issues/436)) ([5cc4ef2](https://github.com/Seb-GRAF/StableBar/commit/5cc4ef210f4d675a34881b43d44c5f588214aa6c)), closes [#435](https://github.com/Seb-GRAF/StableBar/issues/435) [#435](https://github.com/Seb-GRAF/StableBar/issues/435)
* give a bar below the menu bar what the menu bar doesn't show ([#469](https://github.com/Seb-GRAF/StableBar/issues/469)) ([1181904](https://github.com/Seb-GRAF/StableBar/commit/118190440c4290cc9ff0bf2821554afd26e3d23e)), closes [#452](https://github.com/Seb-GRAF/StableBar/issues/452)
* hold Edit Bar in Place until setup is done ([7582976](https://github.com/Seb-GRAF/StableBar/commit/7582976ff532fb98f8e8031afabbad8c8c89292e)), closes [#462](https://github.com/Seb-GRAF/StableBar/issues/462)
* keep a bar below the menu bar clear of it on every display ([#468](https://github.com/Seb-GRAF/StableBar/issues/468)) ([ff1d0e9](https://github.com/Seb-GRAF/StableBar/commit/ff1d0e9aefd180e6261822f8ead82e9f7cd5fe8a)), closes [#451](https://github.com/Seb-GRAF/StableBar/issues/451)
* keep a cancelled hover from showing a tooltip or closing its popup late ([#483](https://github.com/Seb-GRAF/StableBar/issues/483)) ([93c44a1](https://github.com/Seb-GRAF/StableBar/commit/93c44a1b03c78206c747483543e99682b1dd1ffd)), closes [#482](https://github.com/Seb-GRAF/StableBar/issues/482)
* keep a package library that outlives its bar from crashing the test run ([#481](https://github.com/Seb-GRAF/StableBar/issues/481)) ([5f4821d](https://github.com/Seb-GRAF/StableBar/commit/5f4821d677c874aa894ae65a3b7b9cabb82022f8)), closes [#480](https://github.com/Seb-GRAF/StableBar/issues/480)
* keep a popup's focus when clicking inside it ([f5ecaec](https://github.com/Seb-GRAF/StableBar/commit/f5ecaec239e00d8d136afef9dea2956ed614dbb8))
* keep setup's buttons above a Dock at the bottom of the screen ([#445](https://github.com/Seb-GRAF/StableBar/issues/445)) ([2784139](https://github.com/Seb-GRAF/StableBar/commit/2784139f1d6a32a1d9116662a7bf46840902052b)), closes [#444](https://github.com/Seb-GRAF/StableBar/issues/444)
* keep setup's pointer below the bar when the menu bar shows ([#509](https://github.com/Seb-GRAF/StableBar/issues/509)) ([ef22935](https://github.com/Seb-GRAF/StableBar/commit/ef22935a60e4f72f9c4a06cf90e88d8b79a0d562))
* keep setup's steps, reminders and hints readable on short screens ([#476](https://github.com/Seb-GRAF/StableBar/issues/476)) ([940777d](https://github.com/Seb-GRAF/StableBar/commit/940777d341134ea3f4b9ae22261292609dd7a5fd)), closes [#455](https://github.com/Seb-GRAF/StableBar/issues/455)
* keep the app menus on the menu bar's app while a background agent is in front ([#446](https://github.com/Seb-GRAF/StableBar/issues/446)) ([a900ef5](https://github.com/Seb-GRAF/StableBar/commit/a900ef5558c44db3b58e7ec4ec7b11f179c6ecaa)), closes [#443](https://github.com/Seb-GRAF/StableBar/issues/443)
* keep the app menus that fit beside the notch and put the rest behind » ([#477](https://github.com/Seb-GRAF/StableBar/issues/477)) ([8b09465](https://github.com/Seb-GRAF/StableBar/commit/8b09465d216e4f3d39f564b0f80e4bf42f2936f9)), closes [#453](https://github.com/Seb-GRAF/StableBar/issues/453)
* keep the focus ring while editing the bar ([80195ff](https://github.com/Seb-GRAF/StableBar/commit/80195ffd0d4e61e171716e980b424128831e34dd))
* keep widgets beside the notch against it when More widgets shows its button ([d74b925](https://github.com/Seb-GRAF/StableBar/commit/d74b925449454fa89f459d8d0e5d256a8661b197))
* leave Battery out of setup's presets on a Mac without a battery ([3db935d](https://github.com/Seb-GRAF/StableBar/commit/3db935d5f308ddcef1477dca4be9dd37ad241ce5)), closes [#456](https://github.com/Seb-GRAF/StableBar/issues/456)
* let Skip setup restore the menu bar when a change is still in flight ([#498](https://github.com/Seb-GRAF/StableBar/issues/498)) ([9fdf1ce](https://github.com/Seb-GRAF/StableBar/commit/9fdf1ced0c2355e175b703a6f176f4f6e4899a4e)), closes [#497](https://github.com/Seb-GRAF/StableBar/issues/497)
* look up private macOS calls at runtime, so a missing one only turns its feature off ([#490](https://github.com/Seb-GRAF/StableBar/issues/490)) ([5f312fd](https://github.com/Seb-GRAF/StableBar/commit/5f312fdf85b67598b450187707a0c5fcdc661b99))
* move a bar an earlier setup put below the menu bar under it ([#475](https://github.com/Seb-GRAF/StableBar/issues/475)) ([9cada9a](https://github.com/Seb-GRAF/StableBar/commit/9cada9a8e2a8e21302e51db656fd82c90ebf98f5)), closes [#468](https://github.com/Seb-GRAF/StableBar/issues/468) [#474](https://github.com/Seb-GRAF/StableBar/issues/474)
* name the profile that sets belowMenuBar in setup's profile notice ([#473](https://github.com/Seb-GRAF/StableBar/issues/473)) ([55aea3c](https://github.com/Seb-GRAF/StableBar/commit/55aea3c2892fe1c0392ae7668043290555271728)), closes [#471](https://github.com/Seb-GRAF/StableBar/issues/471)
* offer the Notch preset only when the bar replaces the menu bar ([#438](https://github.com/Seb-GRAF/StableBar/issues/438)) ([dc5a611](https://github.com/Seb-GRAF/StableBar/commit/dc5a61163eb9dabf8904e4994858f995b9d9c7f7)), closes [#437](https://github.com/Seb-GRAF/StableBar/issues/437)
* reject a negative group flare ([eae8615](https://github.com/Seb-GRAF/StableBar/commit/eae861547020fde926e15d30c9682bd2b0c5311a))
* show workspace managers as segments in Settings again ([60e21a5](https://github.com/Seb-GRAF/StableBar/commit/60e21a5249336dcfb19114822e3418a54fc61606))
* start a new bar with a clock in the Mac's date order and 12- or 24-hour time ([#501](https://github.com/Seb-GRAF/StableBar/issues/501)) ([ed119f7](https://github.com/Seb-GRAF/StableBar/commit/ed119f7b353d0f61c84678209bc1085efc47e561))
* stop reopening setup at every launch after Skip setup ([#472](https://github.com/Seb-GRAF/StableBar/issues/472)) ([a15e07a](https://github.com/Seb-GRAF/StableBar/commit/a15e07aef2bc424a5c7f716c1e705c6f7ae45d29)), closes [#449](https://github.com/Seb-GRAF/StableBar/issues/449)

## [0.11.0](https://github.com/Seb-GRAF/StableBar/compare/v0.10.0...v0.11.0) (2026-11-06)

### Features

* ask people once to star StableBar on GitHub ([355bb84](https://github.com/Seb-GRAF/StableBar/commit/355bb847482ec9f4543cb4fd10dbc19eb478dd34)), closes [#423](https://github.com/Seb-GRAF/StableBar/issues/423)
* draw setup in the website's felt-pen ink over its lighthouse hill ([bf028e6](https://github.com/Seb-GRAF/StableBar/commit/bf028e67a6d97027f363e98ea0bce4c94ab7e360))
* open an app's menu bar item from a popup block ([3f261fd](https://github.com/Seb-GRAF/StableBar/commit/3f261fd34e3cefa4d270fd845e4a94bdf0ce2226))
* show keyboard shortcuts in app menus ([b43438e](https://github.com/Seb-GRAF/StableBar/commit/b43438ed5e12427b9c53a699f70fb93ffb7e757a)), closes [#418](https://github.com/Seb-GRAF/StableBar/issues/418)
* use the lighthouse logo across the app and website ([#420](https://github.com/Seb-GRAF/StableBar/issues/420)) ([ace99e8](https://github.com/Seb-GRAF/StableBar/commit/ace99e8dcaa222c913af7be4cb5438b143c888f8))

### Bug Fixes

* count a wrapped tray's + as a row when dropping a widget ([b40077f](https://github.com/Seb-GRAF/StableBar/commit/b40077f7f394991c56e9aaf2d68639f04457952d))
* draw Gruvbox's focused workspace as a block on the website ([0cc42c6](https://github.com/Seb-GRAF/StableBar/commit/0cc42c6257b30048830259f8597ae59e1886d39e))
* keep a dragged widget at the end when its preview wraps onto a new row ([f3cce03](https://github.com/Seb-GRAF/StableBar/commit/f3cce03a031d0ea972007673c15cef1fa7f92c13))
* keep Settings controls clickable above the bar preview ([43192fa](https://github.com/Seb-GRAF/StableBar/commit/43192fa9c335578a04e35217dab0b1959de51a17))
* line up Gruvbox's text with its icons and stripes and fill its focused workspace ([485c3cf](https://github.com/Seb-GRAF/StableBar/commit/485c3cf051d3dd27a11f0cb2f93f857b1928a600))
* reject negative modifiers in a scene's sample menu ([b43e88e](https://github.com/Seb-GRAF/StableBar/commit/b43e88ee362f5bc83ea4f5b69c1db616136ceaee)), closes [#418](https://github.com/Seb-GRAF/StableBar/issues/418)
* show the right-to-left Return glyph as ↪ in app menus ([7243cff](https://github.com/Seb-GRAF/StableBar/commit/7243cff25249ea758a5c7cfd6edee13421c1b752)), closes [#418](https://github.com/Seb-GRAF/StableBar/issues/418)
* wrap a crowded position onto more rows while editing the bar in place ([61528de](https://github.com/Seb-GRAF/StableBar/commit/61528de14fb1adb5f47e944e6435f0ba381566ca)), closes [#428](https://github.com/Seb-GRAF/StableBar/issues/428)

## [0.10.0](https://github.com/Seb-GRAF/StableBar/compare/v0.9.0...v0.10.0) (2026-11-02)

### Features

* let a slider end in a separate stop past its range, such as ∞ ([d56745c](https://github.com/Seb-GRAF/StableBar/commit/d56745c91826f417f4d99fc10085e5ba81ae06fe)), closes [#399](https://github.com/Seb-GRAF/StableBar/issues/399)
* let the Apple logo open the Apple menu, System Settings or lock the Mac ([f7dab87](https://github.com/Seb-GRAF/StableBar/commit/f7dab87f38aad32e83d1940f249e68755faf4caf)), closes [#411](https://github.com/Seb-GRAF/StableBar/issues/411)
* show script list entries horizontally ([baa1c7e](https://github.com/Seb-GRAF/StableBar/commit/baa1c7e1485d0dab3ad1bcbafe0a915544af7ffa))

### Bug Fixes

* draw graphs from the right and start the CPU at its real use ([d94f70b](https://github.com/Seb-GRAF/StableBar/commit/d94f70b261dd86e6b83fe1d368797b0c24a5ee36))
* draw text-only focused workspaces without a fill in theme previews ([9f8a242](https://github.com/Seb-GRAF/StableBar/commit/9f8a2428a8e2cac359a68c8e3d3013e28e7e53f0)), closes [#400](https://github.com/Seb-GRAF/StableBar/issues/400)
* finish the Settings uninstall after StableBar quits ([51d89e1](https://github.com/Seb-GRAF/StableBar/commit/51d89e112d7e67f9c22f177dc56dc2765e4b588c)), closes [#413](https://github.com/Seb-GRAF/StableBar/issues/413)
* give the Bar page's preview room and narrow its tabs ([37a222e](https://github.com/Seb-GRAF/StableBar/commit/37a222e0ba5418c9a2a06036f0740b1966b0eff9)), closes [#402](https://github.com/Seb-GRAF/StableBar/issues/402)
* hide widgets that have nothing to show and show the icon of one that failed ([227177c](https://github.com/Seb-GRAF/StableBar/commit/227177c53e2381f6002c53120d4ecd1a84a538ea))
* keep the Apple logo on the bar until its menu is read and count empty menus ([340a5d4](https://github.com/Seb-GRAF/StableBar/commit/340a5d4c41e33276f554f88acf6ceb0badcf914d))
* let an Apple widget's own command, link, popup or menu take its click ([1498d44](https://github.com/Seb-GRAF/StableBar/commit/1498d44c5651f5579f62261a3aec9ce2935e8297))
* let an empty menu take the click of an Apple widget with its own layout ([4e91809](https://github.com/Seb-GRAF/StableBar/commit/4e91809e0cc9f4b29a99c4d0d23609deb30f03f8))
* refresh the Apple menu's access state for a widget with its own layout ([b34715e](https://github.com/Seb-GRAF/StableBar/commit/b34715e93002717f15cd2f4b48922de9cc3821c9))
* run the Apple logo's click with a custom layout and check that the Mac locked ([98fd09e](https://github.com/Seb-GRAF/StableBar/commit/98fd09e521b043716237fc0dcd65b17868f6fd1e))
* say Uninstall finishes once StableBar quits ([db2df2c](https://github.com/Seb-GRAF/StableBar/commit/db2df2cf7401502dd084ce76ad5e5c8042d4d822))
* tell Homebrew users to quit StableBar before brew uninstall ([3029aae](https://github.com/Seb-GRAF/StableBar/commit/3029aaec4e77c3b40de32deec4e56fcf4a1416ff))

## [0.9.0](https://github.com/Seb-GRAF/StableBar/compare/v0.8.0...v0.9.0) (2026-10-29)

### Features

* choose the preset and theme in one setup step ([96e07e2](https://github.com/Seb-GRAF/StableBar/commit/96e07e2628792c416093adda3d523ea41e090ef8))
* copy a bug report with versions, displays, access and crashes ([0f61497](https://github.com/Seb-GRAF/StableBar/commit/0f61497133251632a4759c5ea7f59c07809fb830)), closes [#93](https://github.com/Seb-GRAF/StableBar/issues/93)
* end setup's intro on the person's own bar ([30817a3](https://github.com/Seb-GRAF/StableBar/commit/30817a3d9e8e7b5f582286bd4fc5ab6d431865f5))
* end setup's presets with sound, battery, the clock and menu bar items ([9369eff](https://github.com/Seb-GRAF/StableBar/commit/9369eff4ce606e14eae5c7526f0f5a480e125692))
* fill setup's presets with sound, battery and menu bar items ([b641296](https://github.com/Seb-GRAF/StableBar/commit/b6412967f8e8c854caec37934540756c004f9b0d))
* install and update StableBar with Homebrew ([490010e](https://github.com/Seb-GRAF/StableBar/commit/490010e6aa66d0a8cf696255ca2256ebe669d687))
* keep seven iconic themes in the theme gallery ([7087aa1](https://github.com/Seb-GRAF/StableBar/commit/7087aa1dbf6a00548f10bac75d67ef17a0ed68c0)), closes [#370](https://github.com/Seb-GRAF/StableBar/issues/370)
* load configurations written for a newer StableBar ([5ed7094](https://github.com/Seb-GRAF/StableBar/commit/5ed7094ed0f18494f65ba4fcd47533ab53955cf0))
* open setup with a line of light that becomes the demo's glass bar ([d58adb7](https://github.com/Seb-GRAF/StableBar/commit/d58adb7a11f663c45dcc6c9aff6586220439c771))
* open widget settings from the bar on Content ([c441cd0](https://github.com/Seb-GRAF/StableBar/commit/c441cd084e290bce6eda5c272f9c06f62afd9cb7))
* show chosen menu bar items on the bar and hide others from the row ([#356](https://github.com/Seb-GRAF/StableBar/issues/356)) ([607810c](https://github.com/Seb-GRAF/StableBar/commit/607810cb0ef7a7861ca8c3461b9e0c2e2850ab3a))
* show each setup preset's widgets and theme ([12a7284](https://github.com/Seb-GRAF/StableBar/commit/12a7284cc117eab3a6fc9d6f44fc8c0bdafead1a))
* show StableBar's crashes in Settings and copy them into a bug report ([d1c127d](https://github.com/Seb-GRAF/StableBar/commit/d1c127d1198f032b1ff61b385d3ef5c68a818ede)), closes [#333](https://github.com/Seb-GRAF/StableBar/issues/333)
* turn the macOS menu bar's auto-hide on or off from Settings ([2e79f5c](https://github.com/Seb-GRAF/StableBar/commit/2e79f5c212c18b7e5d0b48372bc4232536538c7e)), closes [#210](https://github.com/Seb-GRAF/StableBar/issues/210)
* uninstall StableBar and turn off the menu bar auto-hide it turned on ([9f3706b](https://github.com/Seb-GRAF/StableBar/commit/9f3706b2ba5240f13f0655a86dd0bba452d2162c)), closes [#332](https://github.com/Seb-GRAF/StableBar/issues/332)

### Bug Fixes

* drag and click widgets on every display while editing the bar in place ([4c93398](https://github.com/Seb-GRAF/StableBar/commit/4c933986f6fc7b100133758bb8af9d85f6bfed2d))
* find tools on the login shell's PATH when the shell is slow at login ([18723df](https://github.com/Seb-GRAF/StableBar/commit/18723df652194443f18fbeed97dd103cd12edb24)), closes [#362](https://github.com/Seb-GRAF/StableBar/issues/362)
* hide the app menus warning while setup is open ([0b521c1](https://github.com/Seb-GRAF/StableBar/commit/0b521c18bd8a22d339a331c1e991764bc38be6d2))
* inset Léman's focused workspace and draw Catppuccin's as a pill ([7206852](https://github.com/Seb-GRAF/StableBar/commit/7206852665826e0e533069ab52500605f5beb43d)), closes [#370](https://github.com/Seb-GRAF/StableBar/issues/370)
* keep clicks on the bar from showing the menu bar on macOS 27 ([4ff45b9](https://github.com/Seb-GRAF/StableBar/commit/4ff45b98eb18a6e2a0048d33e4eb3baac38920f7)), closes [#366](https://github.com/Seb-GRAF/StableBar/issues/366)
* keep hover popups open while moving toward them ([0fe1fed](https://github.com/Seb-GRAF/StableBar/commit/0fe1fed26a73384e3f1e9d18650fcc0fd70b7659))
* keep the menu bar reveal delay working on macOS 27 ([86f6f30](https://github.com/Seb-GRAF/StableBar/commit/86f6f305a3c4a3180deebbf6e44f0246b0e506d8)), closes [#367](https://github.com/Seb-GRAF/StableBar/issues/367)
* land a dropped widget in its slot without the bar jumping ([d23917c](https://github.com/Seb-GRAF/StableBar/commit/d23917c356ada3fe7f3dfffb5db93d5932d156a5))
* prevent command cancellation deadlocks and flaky test failures ([48e128b](https://github.com/Seb-GRAF/StableBar/commit/48e128b4dc5827aa5e40e1330f667c81895c3904))
* put the bar back above the menu bar strip after the screen locks ([a934459](https://github.com/Seb-GRAF/StableBar/commit/a9344594363e094f1c04c4444e4126ef0927ab0a)), closes [#374](https://github.com/Seb-GRAF/StableBar/issues/374)
* show the menu bar's items in Menu bar items on macOS 27 ([4a00c35](https://github.com/Seb-GRAF/StableBar/commit/4a00c3565e20b5c00cbb0f851d32ac021aa0cef2)), closes [#372](https://github.com/Seb-GRAF/StableBar/issues/372)

### Performance Improvements

* bounce the equalizer without updating the bar every frame ([756795a](https://github.com/Seb-GRAF/StableBar/commit/756795ade97ba01518636d7ed6149594e072940c))
* keep the bar moving while a widget move saves ([033e5aa](https://github.com/Seb-GRAF/StableBar/commit/033e5aa0bd87262025e9cf237b52caa116f71f52))

## [0.8.0](https://github.com/Seb-GRAF/StableBar/compare/v0.7.0...v0.8.0) (2026-10-26)

### Features

* add settings to magnify ([236e31f](https://github.com/Seb-GRAF/StableBar/commit/236e31fac5f6c11ebb1f44af2b45ee3b3ce18ef8))
* draw the More widgets button like the other widgets ([33b2b89](https://github.com/Seb-GRAF/StableBar/commit/33b2b892debc939fb48cecdbecca2fe99618ed80))
* keep the macOS menu bar hidden while StableBar runs ([525a78d](https://github.com/Seb-GRAF/StableBar/commit/525a78d3473c7bc89a64f9991c2aea63c4389004))
* open a package in Settings from a stablebar:// link ([96e37ed](https://github.com/Seb-GRAF/StableBar/commit/96e37eddbeb8ec472381a9968b40bfe67637d5c2))
* open app menus in a row under the bar when they can't expand in place ([008bd1a](https://github.com/Seb-GRAF/StableBar/commit/008bd1ad3ef1535da618d755f4acbee3242fdc45))
* open app menus in StableBar's popup instead of a native menu ([ed31bb3](https://github.com/Seb-GRAF/StableBar/commit/ed31bb3a93d087c22260fcc7e0d56745bddb89b5))
* open Control Center and the macOS menu bar's items from the bar ([d4581b7](https://github.com/Seb-GRAF/StableBar/commit/d4581b76888092c6ac3b205be41aca561a4e3ed1))
* open the Menu bar items row on hover ([35101f7](https://github.com/Seb-GRAF/StableBar/commit/35101f7cc75c2d9a0636a24ead6c98807fba86ea)), closes [#320](https://github.com/Seb-GRAF/StableBar/issues/320)
* overflow widgets at the notch into a popup of the widgets themselves ([22fc098](https://github.com/Seb-GRAF/StableBar/commit/22fc0985e2dbfd7b82240a8a162a16ca9f9dd9a4))
* put the More widgets button beside the nearest widget ([d7b5dc2](https://github.com/Seb-GRAF/StableBar/commit/d7b5dc2b3b46062a9c40800e48bdbbda2cd83c14))
* show hover controls in an animated tooltip instead of widening the widget ([795314d](https://github.com/Seb-GRAF/StableBar/commit/795314d8dc52a3238b2fd43f1bdb8de1e022399b))
* show the app menus on the starter bar instead of the active app ([1ed79e6](https://github.com/Seb-GRAF/StableBar/commit/1ed79e6108aca39d441a5e5bfb2742b033dacb1d))
* show the Menu bar items widget as a grid symbol ([5614188](https://github.com/Seb-GRAF/StableBar/commit/56141881f1a1c4f1e72ab166db1b37c7279f8b50))

### Bug Fixes

* accept workspace icon drops on every workspace ([fa94634](https://github.com/Seb-GRAF/StableBar/commit/fa94634767c5c733f482d19e890430491388d18e)), closes [#280](https://github.com/Seb-GRAF/StableBar/issues/280)
* center the Sound widget's speaker in its icon ([d19673c](https://github.com/Seb-GRAF/StableBar/commit/d19673cb46e88bc5c4c5ee8bb57cc7154ad29ef3))
* handle workspace icon drops through AppKit ([8ecfefa](https://github.com/Seb-GRAF/StableBar/commit/8ecfefab94f8f5bc092d9c651a7e92960a8d13da)), closes [#280](https://github.com/Seb-GRAF/StableBar/issues/280)
* keep a widget that expands on hover on the bar ([53e63ff](https://github.com/Seb-GRAF/StableBar/commit/53e63ff94124f40aaf27dedd77c9ce5a1335f97f))
* keep long tooltips inside their card ([d343be3](https://github.com/Seb-GRAF/StableBar/commit/d343be3b893d90f60bd22fab11951f60f66226d4))
* relaunch the bar after an update while a triage session runs ([1c879da](https://github.com/Seb-GRAF/StableBar/commit/1c879da442744b3461773d52e12271330fa3e3a4)), closes [#281](https://github.com/Seb-GRAF/StableBar/issues/281)
* show the right icons in the Menu bar items row ([a9d1d32](https://github.com/Seb-GRAF/StableBar/commit/a9d1d323f1e1d67051d17651898f2fc3e41bc0f2)), closes [#323](https://github.com/Seb-GRAF/StableBar/issues/323)

## [0.7.0](https://github.com/Seb-GRAF/StableBar/compare/v0.6.0...v0.7.0) (2026-10-23)

### Features

* ask an agent from a popup that you can pin, resize and keep on screen ([c96664e](https://github.com/Seb-GRAF/StableBar/commit/c96664e7fe8285a4d6a90b8fa3701ac6d5d3c6ba))
* fold common Store widgets into Essentials ([a98afdc](https://github.com/Seb-GRAF/StableBar/commit/a98afdc8b481133232dcd076523b3ffd1d10ab4e))
* install the stablebar command from Settings ([2f2f4b8](https://github.com/Seb-GRAF/StableBar/commit/2f2f4b8f0c38ef9988f4132dd12f3094bf19329b)), closes [#255](https://github.com/Seb-GRAF/StableBar/issues/255)
* investigate a problem or an idea with a coding agent ([cc71625](https://github.com/Seb-GRAF/StableBar/commit/cc71625e13e9854fd5b915f03a03030265186ebb)), closes [#257](https://github.com/Seb-GRAF/StableBar/issues/257)
* move windows by dragging workspace icons ([dd23b08](https://github.com/Seb-GRAF/StableBar/commit/dd23b08d840c10b336daf50994072e1a28ec2085)), closes [#270](https://github.com/Seb-GRAF/StableBar/issues/270)
* show OmniWM workspaces in workspace widgets ([0087096](https://github.com/Seb-GRAF/StableBar/commit/00870962171cb6a59e1d2fb9d8401e645bee3bfe)), closes [#267](https://github.com/Seb-GRAF/StableBar/issues/267)

### Bug Fixes

* draw a popup's shadow without blacking out its Liquid Glass ([6a1acba](https://github.com/Seb-GRAF/StableBar/commit/6a1acbaa7856455db1855c437ea2c8aec84cd108))
* keep the glass steady when a popup morphs into another ([72f8b0e](https://github.com/Seb-GRAF/StableBar/commit/72f8b0ea5e116aa577b169f64b2be8443f57e564))
* let ⌘V, ⌘C, ⌘X and ⌘A work in Settings text fields ([0ca55be](https://github.com/Seb-GRAF/StableBar/commit/0ca55be3240b75c3c3302d06732893a879a76059)), closes [#258](https://github.com/Seb-GRAF/StableBar/issues/258)
* recover Essentials upgrades from official local packages ([84dda11](https://github.com/Seb-GRAF/StableBar/commit/84dda11bd45d2e67e017463897e9f69553cb21b4))

## [0.6.0](https://github.com/Seb-GRAF/StableBar/compare/v0.5.0...v0.6.0) (2026-10-23)

### Features

* add a delay before the native menu bar appears ([#202](https://github.com/Seb-GRAF/StableBar/issues/202)) ([d462e69](https://github.com/Seb-GRAF/StableBar/commit/d462e69bfd412eb3ad1944df239ac1df08a0dbc7))
* add animation presets and popup transitions ([#192](https://github.com/Seb-GRAF/StableBar/issues/192)) ([22aa125](https://github.com/Seb-GRAF/StableBar/commit/22aa1250ccd1170dde2f205617ce2f11571fd208))
* add compact battery and sound display settings ([0cb7a90](https://github.com/Seb-GRAF/StableBar/commit/0cb7a90ef1188a846146957a3349e5a23901a9d4))
* add private package sources ([a4e6a08](https://github.com/Seb-GRAF/StableBar/commit/a4e6a08290e2870bf008dcd1bfc6fd7a51ed4501)), closes [#248](https://github.com/Seb-GRAF/StableBar/issues/248)
* add, remove and choose screens for widgets from the Bar list ([b441fc4](https://github.com/Seb-GRAF/StableBar/commit/b441fc49628924972e71c4a18f12305b8e659c49))
* apply Theme changes to every screen setup ([170be42](https://github.com/Seb-GRAF/StableBar/commit/170be4262b8f39c6dfcf607e3883d9514fa84b11))
* build, demo and land the bar in the setup intro ([#178](https://github.com/Seb-GRAF/StableBar/issues/178)) ([4e23a0b](https://github.com/Seb-GRAF/StableBar/commit/4e23a0b56bbb7304af0c76fd88d607608fa312fb))
* change the volume with a slider when hovering the Sound widget ([4a0dab0](https://github.com/Seb-GRAF/StableBar/commit/4a0dab02f53dd5861cde642feeb0b664466e2688))
* fade popups in with a shadow and the system material ([#170](https://github.com/Seb-GRAF/StableBar/issues/170)) ([bec220b](https://github.com/Seb-GRAF/StableBar/commit/bec220b049b424739ad432719696797a0f99f178))
* give the installer a drag-to-install layout ([#176](https://github.com/Seb-GRAF/StableBar/issues/176)) ([4d42155](https://github.com/Seb-GRAF/StableBar/commit/4d421551e8c1548a3b5b45f41d01a060d1904b46))
* lead setup to replace the macOS menu bar ([#198](https://github.com/Seb-GRAF/StableBar/issues/198)) ([4160f7f](https://github.com/Seb-GRAF/StableBar/commit/4160f7f4c04631356b63ece8fbdbafa863313f8e))
* list the apps using the most memory and CPU and quit them from the system monitor ([#234](https://github.com/Seb-GRAF/StableBar/issues/234)) ([1659bfb](https://github.com/Seb-GRAF/StableBar/commit/1659bfb9f9bbbeea2c678e60f8af625ce67e4ad6))
* make the installed package list easier to scan ([#228](https://github.com/Seb-GRAF/StableBar/issues/228)) ([36a3532](https://github.com/Seb-GRAF/StableBar/commit/36a3532656556a22f349cb9d21baae256133e68b))
* morph between popups by default ([0371fc2](https://github.com/Seb-GRAF/StableBar/commit/0371fc240156d03a8a6cdf8d8f6901e7b8880e57))
* morph the open popup into the next one when switching widgets ([#204](https://github.com/Seb-GRAF/StableBar/issues/204)) ([e944864](https://github.com/Seb-GRAF/StableBar/commit/e944864a72653a465b2ad5e5f7996934c21db351))
* notify about package updates in the bar ([#153](https://github.com/Seb-GRAF/StableBar/issues/153)) ([542c8dc](https://github.com/Seb-GRAF/StableBar/commit/542c8dce15c37a39a324b789d78f223fa83c5af2))
* open and close a widget's popup from the command line ([#193](https://github.com/Seb-GRAF/StableBar/issues/193)) ([865686c](https://github.com/Seb-GRAF/StableBar/commit/865686c687ddb6df0f607e2aba6b5cbaa693ca38))
* open the setup tour with an intro that turns into your bar ([f4cdfc5](https://github.com/Seb-GRAF/StableBar/commit/f4cdfc5266f96db1c2c99faaf952faca765ac561))
* put new bars on the top edge and offer to hide the menu bar ([4be3235](https://github.com/Seb-GRAF/StableBar/commit/4be3235e467d8dc627a0dc6720efe2651887a280))
* redesign Settings with per-screen bars and themes ([15ae182](https://github.com/Seb-GRAF/StableBar/commit/15ae182fc141307d1b053136b89542ae6b86f6ed))
* refresh the app icon ([ed5070e](https://github.com/Seb-GRAF/StableBar/commit/ed5070e05a2ffe5ec02c2c861c12aea259aac241))
* reorder bar widgets like the Dock ([#167](https://github.com/Seb-GRAF/StableBar/issues/167)) ([8fa078e](https://github.com/Seb-GRAF/StableBar/commit/8fa078ecc75e816e33f8330b58f7d921b553bbb7))
* reveal hover controls smoothly beside widgets ([7fe3c45](https://github.com/Seb-GRAF/StableBar/commit/7fe3c45e4c246505cd6aecc764c197ef07ff8769))
* save the current look as a theme ([aef6cdc](https://github.com/Seb-GRAF/StableBar/commit/aef6cdc14919c3521b2f81b13333f29d23bf4fe1))
* ship ten more themes with distinct looks ([#232](https://github.com/Seb-GRAF/StableBar/issues/232)) ([8cc1e24](https://github.com/Seb-GRAF/StableBar/commit/8cc1e249ca55ec607dbcd15e66ea7156efedf62c))
* show macOS Spaces in workspace widgets without a tiling window manager ([fbc5746](https://github.com/Seb-GRAF/StableBar/commit/fbc57466bdaa1a9a0727afe8cbac71a531216e79))
* show previews throughout the package list ([#152](https://github.com/Seb-GRAF/StableBar/issues/152)) ([103297a](https://github.com/Seb-GRAF/StableBar/commit/103297a4036bc7c0ee9946f9c82d9590f5f036f6))
* show Store packages with updates first, then installed ones, then the rest ([14d4441](https://github.com/Seb-GRAF/StableBar/commit/14d4441762cd8a18c9c715fc72c3a10f377adb8c)), closes [#242](https://github.com/Seb-GRAF/StableBar/issues/242)
* show the battery's charge, power and health in its icon, with the percentage in a tooltip ([fa990a7](https://github.com/Seb-GRAF/StableBar/commit/fa990a7a223bea9911c341a70fb235f3e2a6a1e5)), closes [#237](https://github.com/Seb-GRAF/StableBar/issues/237)
* show the Store as a grid of package cards ([#236](https://github.com/Seb-GRAF/StableBar/issues/236)) ([0c5c7ee](https://github.com/Seb-GRAF/StableBar/commit/0c5c7ee4e58a86472bb42f0e3353847e27f4332a))
* show the volume level in the Sound widget's speaker ([4ae9c82](https://github.com/Seb-GRAF/StableBar/commit/4ae9c82341ec3cc6861d62a986020ce1a82d2b20))
* show the volume only for a moment after it changes ([2fa27b2](https://github.com/Seb-GRAF/StableBar/commit/2fa27b2dcd0d79926b79f95578cf21da7889136d))
* slide between app menus like the macOS menu bar ([#171](https://github.com/Seb-GRAF/StableBar/issues/171)) ([82b487b](https://github.com/Seb-GRAF/StableBar/commit/82b487be459a579d3bf30029fcbdb5261a9a248c))
* turn setup into a tour that changes the bar live ([24ba8c0](https://github.com/Seb-GRAF/StableBar/commit/24ba8c0301464724ca8c21c90111aa90fe2f0808))
* update packages on the bar in one click ([7f0191d](https://github.com/Seb-GRAF/StableBar/commit/7f0191dced5ca574dbb9bb0431360f13ecbd2925))
* use the menu bar's 13pt regular font by default ([#173](https://github.com/Seb-GRAF/StableBar/issues/173)) ([d3a2b96](https://github.com/Seb-GRAF/StableBar/commit/d3a2b96783b9ffb37134992be1ed8889162a0b6c))

### Bug Fixes

* correct eight bugs found in the app audit ([#240](https://github.com/Seb-GRAF/StableBar/issues/240)) ([da0666d](https://github.com/Seb-GRAF/StableBar/commit/da0666d5214204150d9b8d255f0d93183e5665f6))
* draw a popup's own shadow without an outline around it ([a9eb602](https://github.com/Seb-GRAF/StableBar/commit/a9eb602f3b29d2c2a87b64d20581105aa6aeb008)), closes [#170](https://github.com/Seb-GRAF/StableBar/issues/170) [#180](https://github.com/Seb-GRAF/StableBar/issues/180)
* ease in and out of bar editing ([#168](https://github.com/Seb-GRAF/StableBar/issues/168)) ([86d6472](https://github.com/Seb-GRAF/StableBar/commit/86d64727cc933d5d8a9c14015f480be52c42b5ca))
* keep number widths steady in default widget layouts ([#169](https://github.com/Seb-GRAF/StableBar/issues/169)) ([a2c34d4](https://github.com/Seb-GRAF/StableBar/commit/a2c34d4583974dac6285170d2d114f7b7103acde))
* keep StableBar running when the setup tour ends ([#177](https://github.com/Seb-GRAF/StableBar/issues/177)) ([7528a25](https://github.com/Seb-GRAF/StableBar/commit/7528a254797f800a7844b6b9ba348886991d406b))
* keep the Settings form the same height while saving or showing errors ([#165](https://github.com/Seb-GRAF/StableBar/issues/165)) ([0caff0c](https://github.com/Seb-GRAF/StableBar/commit/0caff0c6080fc8205f0bbce006f92b96997bac3d))
* keep the Settings layout steady while you change it ([#163](https://github.com/Seb-GRAF/StableBar/issues/163)) ([0a18461](https://github.com/Seb-GRAF/StableBar/commit/0a18461752e13d85ef4d6d04e624ba974dabaf44))
* move popups smoothly and at once when morphing between them ([0538bba](https://github.com/Seb-GRAF/StableBar/commit/0538bba93139c800296d127d3f82b96c3c1b37a9))
* open tooltips at their size instead of zooming in ([431ee36](https://github.com/Seb-GRAF/StableBar/commit/431ee3617f189b20652b0838255cb7dbc48bf0ea)), closes [#244](https://github.com/Seb-GRAF/StableBar/issues/244)
* remember where the Settings window was ([#166](https://github.com/Seb-GRAF/StableBar/issues/166)) ([f1f5281](https://github.com/Seb-GRAF/StableBar/commit/f1f52814926347fef7726cdf0d43141705bf34c2))
* save typed numbers in Settings without pressing Return ([#230](https://github.com/Seb-GRAF/StableBar/issues/230)) ([d37bfd2](https://github.com/Seb-GRAF/StableBar/commit/d37bfd2d60a5880c04fd6cba966845024d1bf923))
* show a Dock icon while Settings is open ([#200](https://github.com/Seb-GRAF/StableBar/issues/200)) ([bee1d3f](https://github.com/Seb-GRAF/StableBar/commit/bee1d3f4b46107c192f1bbe8e312638e0def8425))
* show hover highlights at once and fade them out quickly ([#172](https://github.com/Seb-GRAF/StableBar/issues/172)) ([d92a292](https://github.com/Seb-GRAF/StableBar/commit/d92a292fc596e5e080ce8654af2c4218af2c6086))
* show hover, cursor and haptic feedback while editing the bar ([#175](https://github.com/Seb-GRAF/StableBar/issues/175)) ([7ec767d](https://github.com/Seb-GRAF/StableBar/commit/7ec767d9ba633f0a1fe73e7533b675fb0a94bb62))
* show only the macOS prompt when asking for Accessibility ([#197](https://github.com/Seb-GRAF/StableBar/issues/197)) ([607958a](https://github.com/Seb-GRAF/StableBar/commit/607958a23822ee259a7b840fc2070c82489d849e))

### Performance Improvements

* keep Settings responsive while changing the bar ([#161](https://github.com/Seb-GRAF/StableBar/issues/161)) ([39035a7](https://github.com/Seb-GRAF/StableBar/commit/39035a734bc084fe9b6d52a820135a9a24b6d481))
* keep the bar smooth while reading app menus and scrolling text ([#174](https://github.com/Seb-GRAF/StableBar/issues/174)) ([22b4972](https://github.com/Seb-GRAF/StableBar/commit/22b49721d443432cda195aeda0d59399ed834cb5))
* reduce CPU use while text scrolls ([#246](https://github.com/Seb-GRAF/StableBar/issues/246)) ([e10a962](https://github.com/Seb-GRAF/StableBar/commit/e10a962506c3e509bae25cc1db196d4ed67729bd))
* update the bar after a pause while typing in the inspector ([#164](https://github.com/Seb-GRAF/StableBar/issues/164)) ([215c051](https://github.com/Seb-GRAF/StableBar/commit/215c051514c24891eba82ff0df6c1f07632db868))

## [0.5.0](https://github.com/Seb-GRAF/StableBar/compare/v0.4.0...v0.5.0) (2026-10-21)

### Features

* add a calendar provider for the next meeting and today's agenda ([451c30a](https://github.com/Seb-GRAF/StableBar/commit/451c30a7a48e2db3aabf56cd4717963d13963b55))
* add a states map to every style ([a4ae6f2](https://github.com/Seb-GRAF/StableBar/commit/a4ae6f249093ef8d372eb6b20cee36ec3ce8a4a1))
* add an equalizer block that bounces while its source is on ([#141](https://github.com/Seb-GRAF/StableBar/issues/141)) ([8e855ee](https://github.com/Seb-GRAF/StableBar/commit/8e855eed93a0350553d7f59e52dbb0cda3ef2cbf))
* add an open state for the widget whose popup shows ([8eb69f4](https://github.com/Seb-GRAF/StableBar/commit/8eb69f443bc456351a5e310feefaac3492613852))
* add Menu Bar, Island, Minimal and Terminal themes that restyle the whole bar ([570ab73](https://github.com/Seb-GRAF/StableBar/commit/570ab733b484ba1cd39aa936bc673abfe12432e3))
* add rules that set data states from provider values and fields ([7c9c70e](https://github.com/Seb-GRAF/StableBar/commit/7c9c70e7c1c40f14545d3b346c08518db9c57022))
* add Tonhalle Line theme and presentation examples ([74449e5](https://github.com/Seb-GRAF/StableBar/commit/74449e59d7b8143229ca735809626021f4ded7c6))
* add widget packages that run no commands ([63efa16](https://github.com/Seb-GRAF/StableBar/commit/63efa165f216500da59a7d766a4f798de4e9f1d7))
* animate changed text and symbols with transitions ([9379e1a](https://github.com/Seb-GRAF/StableBar/commit/9379e1a057848ccc808249505028c15635d082cc))
* animate the active app widget to fit the app's name ([0a00e3f](https://github.com/Seb-GRAF/StableBar/commit/0a00e3f490e6b14c07921090a67f6c3991d196f2))
* ask before enabling an update that adds commands, hosts or permissions ([b623d76](https://github.com/Seb-GRAF/StableBar/commit/b623d76c0577574c27f8272c038b6c7361b6cac1))
* browse and install packages from the store ([b739dfc](https://github.com/Seb-GRAF/StableBar/commit/b739dfcaa58f247fac6338861079fcb972650f46))
* check for and install updates in the app, on a stable or beta track ([f852a25](https://github.com/Seb-GRAF/StableBar/commit/f852a25b87b9864c2b2c2315cff361a653162110))
* customize StableBar without editing the configuration file ([#103](https://github.com/Seb-GRAF/StableBar/issues/103)) ([915e46b](https://github.com/Seb-GRAF/StableBar/commit/915e46b39301de8c4305149f1d5576d54106aa30))
* draw widgets, popups and the bar with Liquid Glass ([7f2310f](https://github.com/Seb-GRAF/StableBar/commit/7f2310fd945801cf08b5c5e3b231d22803516854))
* edit every property the bundled themes set in Customize ([d1fe47c](https://github.com/Seb-GRAF/StableBar/commit/d1fe47c539610aa90dc51be37b85c317355b491d))
* fade or roll widgets in and out when their output hides them ([664d856](https://github.com/Seb-GRAF/StableBar/commit/664d85694787dff99dcffcf09c6c08d39111ef87))
* give clock layouts the time and show every widget's text in Diagnostics ([8dde579](https://github.com/Seb-GRAF/StableBar/commit/8dde579aa132b35fb1d0f04dc4b0fab696ad7f74))
* give colors light and dark values and ship the built-in look and three themes ([5d7c90c](https://github.com/Seb-GRAF/StableBar/commit/5d7c90c0b1875cd84adf98f55c8dd69b334b9393))
* give each screen setup its own bar ([d71a203](https://github.com/Seb-GRAF/StableBar/commit/d71a203f56700405b2776a9307b106082a293a2b))
* keep notification banners clear of the bar ([56872dc](https://github.com/Seb-GRAF/StableBar/commit/56872dc8862dadf4a1e907b95541043599f02ecc))
* keep one Customize item in the bar's menus and move their other actions to General ([2484317](https://github.com/Seb-GRAF/StableBar/commit/2484317eaf21ffb12332d694902bd587f31a0921))
* keep package secrets in the Keychain ([bc29768](https://github.com/Seb-GRAF/StableBar/commit/bc29768bc2eb84b1fdcd4653eaa4ed62072ad0ff))
* keep windows clear of the bar with Accessibility ([d18f156](https://github.com/Seb-GRAF/StableBar/commit/d18f156db9563e60a6c007be04cf9fb0c750a80e))
* let script and provider output set a data state ([0581fa0](https://github.com/Seb-GRAF/StableBar/commit/0581fa06a62c639e7bcf53a1744fe8d1eb73f9e5))
* list the permissions that enabled data sources need in setup ([8e21d1d](https://github.com/Seb-GRAF/StableBar/commit/8e21d1dedd50b7f9894a06060b92194602a269c6))
* merge profiles by name across configuration layers ([7f0f2ed](https://github.com/Seb-GRAF/StableBar/commit/7f0f2ed6113d650c5d5ff717122cc3d7ae1568f6))
* offer presets in setup instead of choosing widget sets ([6473009](https://github.com/Seb-GRAF/StableBar/commit/647300926f86ef01bbe75220430d230f7e7b716a))
* offer sets of built-in widgets in setup ([be2d9fc](https://github.com/Seb-GRAF/StableBar/commit/be2d9fce3dc7a1bdcabc68790c84561732bd0af0))
* open popups on hover and add themed tooltips ([0ba0814](https://github.com/Seb-GRAF/StableBar/commit/0ba081427d7616ff2af218395e582626dd3ed690))
* open URLs and apps from widgets without a shell ([8338ff9](https://github.com/Seb-GRAF/StableBar/commit/8338ff92775bc605ffd9b706659fe425f13ccd1a))
* organize Customize around the bar's look and show where each style comes from ([be1ca77](https://github.com/Seb-GRAF/StableBar/commit/be1ca77920fa44460c98a1f4291d5248eac46d7d))
* pick a theme from installed theme packages ([b600218](https://github.com/Seb-GRAF/StableBar/commit/b60021867f316573ef6bf95e3b58f61625259cfe))
* preview widget sets live on cards and place them beside the app and clock ([fc1a3ff](https://github.com/Seb-GRAF/StableBar/commit/fc1a3ffd18a6d975b8fcd31e26f42abff67fef9a))
* register data source types in one table and show each widget's source in Diagnostics ([45b9f3a](https://github.com/Seb-GRAF/StableBar/commit/45b9f3adbe6c072eaa4ab9628ab695ef2eedffe2))
* remove a saved package secret from the Packages tab ([ac51e7c](https://github.com/Seb-GRAF/StableBar/commit/ac51e7cccd60df63d6a4e2a9775d4159ef7ab2d0))
* replace bundled themes with the community collection ([04b0077](https://github.com/Seb-GRAF/StableBar/commit/04b0077f5f2868853a5f578cbcacea737086102c))
* send power source changes to subscribed scripts ([054d9ae](https://github.com/Seb-GRAF/StableBar/commit/054d9ae522f2ced8406cf4790c163cd0509297b3))
* set the bar's background in Customize ([bff824e](https://github.com/Seb-GRAF/StableBar/commit/bff824e91edfdbe7665de46602225ae36f717888))
* share theme presentation across widgets and bar layout ([7db7ffe](https://github.com/Seb-GRAF/StableBar/commit/7db7ffe6c3c9154bef34a450257056d4e1d8dc39))
* ship a sketchybar-app-font glyph set and match app name prefixes ([b23a4b0](https://github.com/Seb-GRAF/StableBar/commit/b23a4b05166d36aca51a5bf93c6cd3e3145cddcd))
* show and focus individual workspace windows ([85dc0a8](https://github.com/Seb-GRAF/StableBar/commit/85dc0a86b619df97e7a02a80cb29aadc3af860b0))
* show skipped releases in a compact update popup ([5319a29](https://github.com/Seb-GRAF/StableBar/commit/5319a2958e7d92a3fb2ff3b1bb3e36f2c50dfa09))
* show temporary output for a set time ([38eb9f9](https://github.com/Seb-GRAF/StableBar/commit/38eb9f921160001e88a6a5a1450ca9717bd5509d))
* show the app version in an About tab ([a0d94fc](https://github.com/Seb-GRAF/StableBar/commit/a0d94fc5f3260a07e14fbe048e4411321a679d56))
* show the frontmost app's menus in an app menu widget ([45400f8](https://github.com/Seb-GRAF/StableBar/commit/45400f88d9866f6075dbabdb436f606ec5420542))
* show what a package needs in its review ([1740483](https://github.com/Seb-GRAF/StableBar/commit/1740483d119c9a92a57e96309b6c306822499aff))
* simplify configuration and onboarding ([03d527b](https://github.com/Seb-GRAF/StableBar/commit/03d527bba53177e1c2e639e7f004dda025671493))
* uninstall installed package versions ([67e641f](https://github.com/Seb-GRAF/StableBar/commit/67e641faf8eee2f61f2fa910dc55c84a48b01868))
* uninstall installed package versions ([#44](https://github.com/Seb-GRAF/StableBar/issues/44)) ([6c49753](https://github.com/Seb-GRAF/StableBar/commit/6c497538878e7769a3533d8035b3011ff5c71c0b))
* update audio widgets and scripts as soon as the volume or output device changes ([05a0e62](https://github.com/Seb-GRAF/StableBar/commit/05a0e621e4ea9a2cd7d92d3dbc4aa0b7438695c5))
* update battery widgets when macOS reports a power change ([1245d3b](https://github.com/Seb-GRAF/StableBar/commit/1245d3b998c38096f695fefc0ff994364721f38b))

### Bug Fixes

* accept uppercase URL schemes and say widgets packages contain no commands ([90e95a5](https://github.com/Seb-GRAF/StableBar/commit/90e95a5d2ba15218bc5c5655350fb0a72fb11441))
* align workspace height and expose vertical padding ([#60](https://github.com/Seb-GRAF/StableBar/issues/60)) ([88198ca](https://github.com/Seb-GRAF/StableBar/commit/88198ca6a70fbc5268de2cb268067a026dc5fd10))
* allow calendar access in Developer ID releases ([1104e93](https://github.com/Seb-GRAF/StableBar/commit/1104e93b6d9347b12d5268d2300c16a96388c9e6))
* allow negative workspace underline offsets ([a172616](https://github.com/Seb-GRAF/StableBar/commit/a172616ae8f8bd12f823b0c32213974a769f1eec))
* allow package secrets only in the environments of a package's own widgets and providers ([6f7e5b9](https://github.com/Seb-GRAF/StableBar/commit/6f7e5b9cc2318293a46abdb051847dfad787a9a4))
* check for the latest release before downloading ([2acbd83](https://github.com/Seb-GRAF/StableBar/commit/2acbd834ea37ef355bbbf8eabd90b149fbd81abf))
* check for updates every four minutes ([1362d62](https://github.com/Seb-GRAF/StableBar/commit/1362d622d3436fdeaf1edf9688da733b71f69b3f))
* draw Blueprint's workspace underline on the widget's bottom border ([948b7dc](https://github.com/Seb-GRAF/StableBar/commit/948b7dc4cc0edef608df26adbedf41b2c0334e36))
* give Blueprint's widgets room in a full-height frame ([077bd53](https://github.com/Seb-GRAF/StableBar/commit/077bd53898589e3c2ae41b912f19ac1bfb82acda))
* give icon-only widgets the height of a line of text ([9a8e8ac](https://github.com/Seb-GRAF/StableBar/commit/9a8e8aca9eddb93433fa241f626b942c4da57837))
* identify local app builds as development ([83a0b4b](https://github.com/Seb-GRAF/StableBar/commit/83a0b4baebd0e5e8ece97646212449b3e1c46309))
* ignore unchanged settings selections ([7ca7324](https://github.com/Seb-GRAF/StableBar/commit/7ca7324c1e93b905385c77f6ca5f7a9178f7be33))
* keep a clicked popup open when glass draws behind its widget ([2569727](https://github.com/Seb-GRAF/StableBar/commit/2569727565bd805a19496ea47f30de5864cb227a))
* keep colors that setup and the starter configuration wrote from hiding a theme ([c6de0a8](https://github.com/Seb-GRAF/StableBar/commit/c6de0a8ed574dca4fa799bf3c7da5e64f8c22c8f))
* keep native workspace icons steady on hover ([8b2b543](https://github.com/Seb-GRAF/StableBar/commit/8b2b54353b216a70abeda6e7af1892ac5e390cd7))
* keep new beta releases in order on GitHub ([ae454b6](https://github.com/Seb-GRAF/StableBar/commit/ae454b625d79145879bc7b7f7bf59c4ac18beb31))
* keep notification clearance from freezing the bar ([546c908](https://github.com/Seb-GRAF/StableBar/commit/546c9082c23f00083b58f281fb0617f96402b013))
* keep popup content at full size while opening ([470b7da](https://github.com/Seb-GRAF/StableBar/commit/470b7da92acdccef149d64e977c53e393ad6aca3))
* keep the bar running when a package's widget and its popup are removed together ([a46a180](https://github.com/Seb-GRAF/StableBar/commit/a46a18071a1187cd7932d2301da036b4565b6190))
* keep the store's errors and unknown kinds from blocking local packages ([9424aaa](https://github.com/Seb-GRAF/StableBar/commit/9424aaa50e56a25d8c31f4c243415a3731060f83))
* keep zoomed windows below the bar ([eb15873](https://github.com/Seb-GRAF/StableBar/commit/eb158730c5efced629b7936f7843da4662087cd6))
* list commands that packages read from fields in their review ([9a50ddf](https://github.com/Seb-GRAF/StableBar/commit/9a50ddf77d25eb8a1cc64abbdd8cfa01c27bd319))
* make the whole popup block clickable ([d84a9b2](https://github.com/Seb-GRAF/StableBar/commit/d84a9b218ce318c5aff3ec2cfabea0c1aba13cfe))
* make the whole widget tile clickable ([3f0f3ac](https://github.com/Seb-GRAF/StableBar/commit/3f0f3acec7f7cecf56802490c1991e8ab1fc956b))
* make the whole widget tile clickable ([#46](https://github.com/Seb-GRAF/StableBar/issues/46)) ([2f36fd6](https://github.com/Seb-GRAF/StableBar/commit/2f36fd66e36833d191dfd644814e280df206006e))
* match update icons to the active theme ([e38f7ff](https://github.com/Seb-GRAF/StableBar/commit/e38f7ff3dcf37a85d7120d97b44505f06270b38e))
* move neighboring widgets when app menus expand ([6263d6f](https://github.com/Seb-GRAF/StableBar/commit/6263d6f640f48c5ed30834228b1592421f3fc445))
* preserve older themes as custom after updates ([a70201e](https://github.com/Seb-GRAF/StableBar/commit/a70201ec3e2d1b30c7db57a83f2b4a04ec90f93b))
* recover app menus after temporary read failures ([1a19cea](https://github.com/Seb-GRAF/StableBar/commit/1a19ceaf0c5cce0915bd28d557e228fbd6a26b45))
* reject contradictory width limits inside states ([026afd4](https://github.com/Seb-GRAF/StableBar/commit/026afd432bcdc373fbb2f3f27adadcbbb3c8d36f))
* render workspace icons at each display resolution ([12c477c](https://github.com/Seb-GRAF/StableBar/commit/12c477cd83aa0ea0790933ba087d202176533db4))
* save only edited package secrets and never lose the saved one ([6a4ff00](https://github.com/Seb-GRAF/StableBar/commit/6a4ff00a02eb98746b47ee8a1808925453bcd503))
* show a store package's source and mark installed store entries ([39f00a6](https://github.com/Seb-GRAF/StableBar/commit/39f00a6fb442cad8976f55d86fb65a8d893ea5f3))
* show the review of the package selected last ([6d5703c](https://github.com/Seb-GRAF/StableBar/commit/6d5703caaecbeb7427f02d938c0cc271d0adbf26))
* show updates sooner and resize the update popup ([618f575](https://github.com/Seb-GRAF/StableBar/commit/618f57542c3d38179a797fe03f7a135ebb2b6d03))
* take removed widgets off the bar while editing it ([#106](https://github.com/Seb-GRAF/StableBar/issues/106)) ([594aa34](https://github.com/Seb-GRAF/StableBar/commit/594aa34e3b70ce9a7d781f2fdd2c42cc8ba80a9a))
* tell Settings and in-place bar editing apart in the menus ([39e8156](https://github.com/Seb-GRAF/StableBar/commit/39e815623cf5dfc7bef0e7a7bfc5fa7523077328)), closes [#131](https://github.com/Seb-GRAF/StableBar/issues/131)
* treat an empty data state name as no state ([557d267](https://github.com/Seb-GRAF/StableBar/commit/557d267243beefe2d425572c009392e196ed018c))
* use widget hover colors for app menus ([f3b0e7d](https://github.com/Seb-GRAF/StableBar/commit/f3b0e7d50f70974d500c4404a4cb3e20219c5108))

### Performance Improvements

* apply only changed script output so repeated updates redraw nothing ([f7e0d0c](https://github.com/Seb-GRAF/StableBar/commit/f7e0d0c0e21742bc02ecfd7c160e5ac51d49bb22))
* build layout blocks without type erasure and keep the measuring copy still ([e39ac94](https://github.com/Seb-GRAF/StableBar/commit/e39ac9482e213508915c96caffcea2eac94d5dcd))
* resolve widget styles in the store so one update redraws only its widgets ([86f8935](https://github.com/Seb-GRAF/StableBar/commit/86f8935e2456f261300f8fbda737bd011205409b))

## [0.4.0](https://github.com/Seb-GRAF/StableBar/compare/v0.3.0...v0.4.0) (2026-10-15)

### Features

* add yabai workspaces and profile editing ([5c30c63](https://github.com/Seb-GRAF/StableBar/commit/5c30c63df6d7924156005931030f079668ca0396))

## [0.3.0](https://github.com/Seb-GRAF/StableBar/compare/v0.2.0...v0.3.0) (2026-10-15)

### Features

* open Customize from the bar's right-click menu ([361f2e8](https://github.com/Seb-GRAF/StableBar/commit/361f2e8c45478b9f46293e33b27e188e137539c5))
* scale the bar separately on built-in and external displays ([c0b6007](https://github.com/Seb-GRAF/StableBar/commit/c0b600725b032b4f4466de993915972781323f5c))

### Bug Fixes

* hide workspace widgets on displays without workspaces and let the row grow ([59dd4d2](https://github.com/Seb-GRAF/StableBar/commit/59dd4d2c1290de897bfedeb483af615ffb18dfbc))
* reject unknown display types and non-positive display scales ([b6d0bbc](https://github.com/Seb-GRAF/StableBar/commit/b6d0bbc2b3a3f3ca734982e033854edbec0fe681))

## [0.2.0](https://github.com/Seb-GRAF/StableBar/compare/v0.1.1...v0.2.0) (2026-10-15)

### Features

* add one-line system, network, battery and audio widgets ([7b39bd8](https://github.com/Seb-GRAF/StableBar/commit/7b39bd83c8e25916edd918f1b6ee21866231fa07))
* edit the live bar and add widget types and bar settings to the editor ([58a7262](https://github.com/Seb-GRAF/StableBar/commit/58a7262cfbeff6e87b88cb22be0ef3c2a8a005ac))
* emit an aerospaceMode event when the AeroSpace mode changes ([54f5441](https://github.com/Seb-GRAF/StableBar/commit/54f5441bd18a082eaf9552e0f70086c219adbf85))
* follow the system light or dark mode by default ([f2b94ab](https://github.com/Seb-GRAF/StableBar/commit/f2b94ab9fbadd37aec4e83885ee18e544d52c785))
* reject unknown configuration properties and publish a JSON schema ([5239970](https://github.com/Seb-GRAF/StableBar/commit/523997091bd65d89e0fd8e69cdcdebbbab612193))
* size popups to their content when no height is set ([e73b2a4](https://github.com/Seb-GRAF/StableBar/commit/e73b2a46b6b6fb9ae884323b6fc2d2efa3724aeb))

### Bug Fixes

* explain in setup and the README how to keep windows clear of the bar ([2ba8fb0](https://github.com/Seb-GRAF/StableBar/commit/2ba8fb0184361132a46ea5bcd2db33cf0b7d2a17))
* find aerospace on the login shell PATH ([ebd9416](https://github.com/Seb-GRAF/StableBar/commit/ebd9416cbf2d5a9ab1a265670d456057611c86a4))
* keep the layout of untouched configuration when saving edits ([a71aacf](https://github.com/Seb-GRAF/StableBar/commit/a71aacf87fb5739cbb50355f420915656184c3f5))
* keep trigger and notification data from replacing login shell variables ([a75eec9](https://github.com/Seb-GRAF/StableBar/commit/a75eec956b1c7c6e60cafb95bdc4ccb3fa62b455))
* refresh the clock once a minute unless its format shows seconds ([21c144b](https://github.com/Seb-GRAF/StableBar/commit/21c144b7019679fdddbea1f054e2e7d416499c5f))
* resolve package image paths from the origin file instead of its label ([55cc4f1](https://github.com/Seb-GRAF/StableBar/commit/55cc4f1881fb9486b37d8840d86bdcc18869a0ca))
* show action errors on their widget and open Customize from the configuration error ([bac4a01](https://github.com/Seb-GRAF/StableBar/commit/bac4a0123ff19e21406bcf0266db65166644d3fc))

### Performance Improvements

* read the login shell environment once instead of per command ([602f83b](https://github.com/Seb-GRAF/StableBar/commit/602f83b375480ab38fe085cfb46f7fff2f77a598))
* reload the configuration on app switches only when a profile matches apps ([39f17de](https://github.com/Seb-GRAF/StableBar/commit/39f17de06234b9fc3a95967511c53134f12e230c))

## [0.1.1](https://github.com/Seb-GRAF/StableBar/compare/v0.1.0...v0.1.1) (2026-10-15)

### Bug Fixes

* build popup sizing with Swift 6.2 ([afeadcd](https://github.com/Seb-GRAF/StableBar/commit/afeadcda000212954cf002d4764b24cb092899de))
