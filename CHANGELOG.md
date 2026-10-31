# Changelog

## v1.1.1 (In Progress)

### English

- Upgrade target selection and confirmation now have Chinese text and show available Hangar item translations.

- Early Access now defaults to five parallel refresh workers; Standard remains at two, and custom worker choices remain available.

- Restored Gift and Apply Upgrade actions for eligible Hangar pledges after RSI changed its gift controls and gifting API.

- Simplified the CCU calculator with clearer ship choices, a compact savings summary, expandable cost and step details, and a visible way to exclude a CCU.

- Removed Idris-M from the CCU calculator's ship choices because it cannot be upgraded.

- Referrals is now marked as an Early Access tool and listed on the Early Access page, using the same member access rules as WBCCU Deals.

- Tap reached referral rewards to open the matching saved Hangar item using the same detail page as Hangar. If several entries match, choose one; missing rewards show a refresh message.

- Browse referral rewards with pictures in Account → Tools. Switch between the new and legacy ladders and see saved referral progress; accounts without the legacy ladder can still browse its rewards.

- Tap either game-access indicator on your profile to see the saved Hangar packages that include that game, with pledge numbers and matching contents.

### 简体中文

- 升级目标选择和确认页面现已补齐中文界面文字，并在有译名时显示机库物品的中文名称。

- 抢先体验现在默认使用 5 个并行刷新任务；标准版仍为 2 个，且仍可自行调整并发数。

- 适配 RSI 更新后的赠送按钮及接口，恢复符合条件的机库物品的“赠送”和“应用升级”操作。

- CCU 计算器现采用更清晰的舰船选项和简洁的节省金额摘要，费用与步骤详情可按需展开，并可直接排除 CCU。

- Idris-M 无法升级，现已从 CCU 计算器的舰船选项中移除。

- 推荐工具现已标注为抢先体验功能，并加入抢先体验页面，与 WBCCU 优惠使用相同的会员访问规则。

- 轻点已达到的推荐奖励，打开机库中对应物品的详情页。多个匹配条目可供选择；未找到对应奖励时会提示刷新机库。

- 在账户工具中浏览推荐奖励图片、切换新旧阶梯，并查看已保存的推荐进度。无法参与旧阶梯的账户仍可浏览其奖励。

- 轻点个人资料中的游戏权限标识，即可查看包含对应游戏的机库组合包、商品编号和匹配的内容。

## v1.1.0 (Released)

### English

- Connection problems are easier to investigate with more detailed support logs. Sensitive login details are filtered out.
- Buy Back quantity badges stay aligned when translated names wrap onto multiple lines.

- Hangar Log updates now follow content changes instead of polling, including edits that retain their IDs. Updates stay buffered while scrolling or editing search, and account switches clear previous rows immediately.

- Hangar share pictures now use the selected item translation mode and the same displayed pledge title as the Hangar list. In Cloud mode, new names remain in English until their translations are reviewed and published.
- Cloud translation submissions now provide a premium appearance count in the private review database, helping prioritize terms seen by Pro subscribers.
- Chinese catalog translations now consistently use straight single quotation marks, including reviewed entries and new machine suggestions.
- Hangar search now keeps its filters and results visible when the keyboard is dismissed. An X in the search field closes and clears the search.
- Debounced search updates no longer replace newer keyboard input, and authentication transitions respect an in-progress account switch.
- The email verification-code field now has a native Paste button, making copied RSI codes quicker to enter.
- The RSI CAPTCHA image stays visible above its code field while the keyboard is open, and the authentication screen can scroll on smaller displays.
- Removed the redundant text-format icon from the CAPTCHA code field.
- Item translation reveals now animate row height when English and Chinese names use different numbers of lines, and clear the color effect when a row leaves the screen.
- Account now shows Star Citizen and Squadron 42 game access in blue and green glass indicators, using RSI's signed-in Games Library entitlements.
- Fixed game access checks that could remain unavailable by matching the Games Library's authenticated GET request and retrying through the app's RSI browser session when a direct request is rejected. Corrected a crash in that fallback when its response was plain text.
- Integrated the Star Citizen and Squadron 42 access indicators into the profile card as a compact glass footer with a center divider and restrained blue and green accents.
- The game-access footer now uses each game's logo and shows access through brightness alone. Entitlements refresh with Account and Full Refresh, then stay in the locally saved account snapshot instead of being requested when the Account tab opens.
- The profile card's game-access footer now uses native Liquid Glass with vivid blue and green halves, a clean center split, and a shorter height. Its tint adapts to dark and light mode over a pure black or white base; the profile artwork stops above it.
- The game-access footer now labels Star Citizen and Squadron 42 in Chinese when the app language is Chinese, with each logo and label centered in its half of the bar. The labels update immediately when the app language changes.
- Fleet ship matching now recognizes both legacy Constellation names and CIG's Mk IV names. The hosted catalog restores the separate Phoenix Emerald entry with its last published MSRP, image, and role.
- Unit tests now use isolated HTTP fixtures, preferences, caches, and temporary storage, with a shared simulator test scheme and automated build and test checks.
- Added opt-in offline performance workloads and pipeline tracing to measure large inventories before optimization.
- Saved accounts now update in Keychain without deleting the previous entry first. Storage failures are shown explicitly and preserve the current account and cached content.
- Refreshes and account actions now reject late results after an account change. Conflicting actions are serialized through authorization and reconciliation, and uncertain submitted actions require review before retrying.

- Snapshot caches now serialize and coalesce writes, preserve recoverable damaged data, migrate legacy files, and report storage failures.
- Refresh dates and content revisions are tracked per section. Full Refresh retains useful cached sections when another section fails.
- Hosted ship feeds now share requests, revalidate with HTTP validators, and retain validated offline fallback data.
- Inventory refresh preserves unchanged images and invalidates only affected source-dependent variants; same-URL changes can revalidate without clearing every image.
- Inventory normalization, direct HTML parsing, and translation-cache loading now execute away from the UI actor.
- Hangar, Fleet, and Buy Back reuse revision-owned groups, lookups, filter flags, and bounded background search indexes.

### 简体中文

- 连接出现问题时，诊断日志会提供更多信息，方便排查原因，并过滤敏感登录信息。
- 翻译后的名称换行时，回购数量标记仍会保持对齐。

- 机库日志改为按内容变化更新，支持同一编号下的内容修改；滚动或编辑搜索时暂存更新，切换账户时立即清除旧账户条目。

- 机库分享图片现在会遵循所选物品翻译方式，并使用与机库列表相同的商品名称。在云端模式下，新名称会保持英文，直到译文审核并发布。
- 云端翻译提交现在会在私有审核数据库中记录 Pro 用户的条目出现次数，帮助确定译文审核优先顺序。
- 中文物品译名统一使用半角单引号，包括已审核条目和新生成的机器译文。
- 收起键盘后，机库搜索筛选和结果会继续显示；搜索框右侧的 X 可关闭并清除搜索。
- 修复延迟搜索更新覆盖新输入文字，以及重新登录流程绕过账户切换保护的问题。
- 邮件验证码输入框新增系统“粘贴”按钮，方便快速输入已复制的 RSI 验证码。
- 输入 RSI 图形验证码时，即使键盘弹出，验证码图片仍会显示在输入框上方；在较小屏幕上也可滚动登录页面。
- 移除了图形验证码输入框左侧多余的文字格式图标。
- 英文与中文物品名称行数不同时，翻译动画现在会平滑调整条目高度；条目离开屏幕时也会清除残留的彩色效果。
- 账户页新增蓝色的 Star Citizen 和绿色的 Squadron 42 玻璃质感权限标识，依据 RSI 登录后的游戏库权益显示状态。
- 修复游戏权限一直显示“暂时无法检查权限”的问题：使用与 RSI 游戏库一致的登录请求，并在直接请求失败时通过应用内的 RSI 浏览器会话重试；同时修复处理该浏览器返回文本时导致的闪退。
- Star Citizen 与 Squadron 42 权限标识现已融入个人资料卡片，成为带中间分隔线、淡雅蓝绿配色的紧凑玻璃质感底栏。
- 游戏权限底栏改用两款游戏的标志，并仅通过亮度显示权限状态；权限数据随“刷新账户”和“全部刷新”更新，保存在本机账户快照中，不再于打开账户页时单独请求。
- 个人资料卡片的游戏权限底栏改用原生液态玻璃效果，蓝绿两半在中间清晰分界，整体高度也更紧凑。色调分别适配深色与浅色模式，底色为纯黑或纯白，背景图止于底栏上方。
- 应用语言为中文时，游戏权限底栏显示“星际公民”和“42中队”；每组图标与文字在各自半栏中居中显示。切换应用语言后，文字会立即更新。
- 舰队资料现可同时匹配旧版星座系列名称和 CIG 新增的 Mk IV 名称；线上舰船目录也恢复了独立的凤凰翡翠版条目及其上次发布的建议售价、图片和定位。
- 单元测试改用独立的网络模拟、偏好设置、缓存与临时存储，并新增共享模拟器测试方案和自动构建测试检查。
- 新增可选的离线性能测试数据和处理阶段追踪，用于在优化前测量大型机库的性能。
- 更新已保存账户时不再先删除原有钥匙串条目；安全存储失败时会明确提示，并保留当前账户与缓存内容。
- 切换账户后会忽略刷新和账户操作的过期结果；有冲突的操作会从身份验证到结果核对全程互斥，已提交但结果不确定的操作须先检查确认，才能重试。

- 快照缓存按顺序合并写入，保留可恢复的损坏数据，兼容旧格式，并明确提示存储失败。
- 各数据区独立记录刷新时间和内容版本；全部刷新时，部分失败不会丢弃其他区域成功更新的数据。
- 舰船云端目录共享并发请求，支持条件验证，并保留已验证的离线备用数据。
- 刷新保留未变化的图片，仅使受影响的来源及其衍生图片失效；同一链接的图片变化也可重新验证，无需清空全部图片。
- 物品标准化、直接 HTTP 页面的解析和翻译缓存读取移至 UI 执行器之外。
- 机库、舰队与回购共享按内容版本管理的分组、查找表、筛选标记及有界的后台搜索索引。

## v1.0.10 (Release Candidate)

### English

- Manage trusted devices entirely inside Hangar Express, including verification codes, device lists, and device removal—without opening a browser.
- Character Repair now supports RSI's latest account system, optional reasons and Issue Council links, plus a visible one-hour cooldown after a successful request.
- One Language setting now controls the app and item names across Hangar, Fleet, and Buy Back. Cloud or Local translation preference is preserved across updates, and Buy Back text is included in Cloud translation review without uploading personal account information.
- Typing, Chinese input, keyboard presentation, and search are smoother, with a convenient button for dismissing the keyboard.
- Account Tools have a cleaner layout. Trusted Devices and Character Repair are available to everyone, while WBCCU Deals is clearly marked and remains exclusive to Early Access.
- Restored online catalogue and translation data, aligned ship roles between Fleet cards and ship details, and improved WBCCU empty-state messaging.

### 简体中文

- 现在可完全在机库通内管理受信任设备，包括输入验证码、查看设备列表和移除设备，无需打开浏览器。
- 角色修复现已适配 RSI 最新的账户系统，修复原因可留空，也可填写 Issue Council 链接；成功提交后会显示一小时冷却时间。
- 现在只需一个“语言”设置，即可同时控制应用界面以及机库、舰队和回购中的物品名称。更新应用后会保留云端或本地翻译方式；回购文本也会加入云端翻译审核，且不会上传个人账户信息。
- 优化了英文与中文输入、键盘弹出和搜索时的流畅度，并新增便捷的收起键盘按钮。
- 账户工具区域采用更简洁的布局。受信任设备和角色修复向所有用户开放，WBCCU 优惠带有清晰标识并继续仅限抢先体验用户使用。
- 恢复了在线舰船目录和翻译数据，统一了舰队卡片与舰船详情中的舰船定位，并改进了 WBCCU 空状态提示。

## v1.0.9 (In Progress)

### Added
- Added a Beta badge and one-time experimental-feature disclaimer before opening WBCCU Deals for the first time.
- Added an Apple Intelligence-inspired left-to-right reveal when Hangar item text changes from English to a translated language, including a subtle multicolor luminous edge and Reduce Motion support.
- Added a translation-method chooser when selecting a translated Hangar item language and after upgrading, with clear Local and Cloud explanations, the current choice preserved, and a reminder that the method can be changed later in Settings.
- Added a WBCCU Deals tool that displays current StarCitizen-Info Warbond upgrade offers with ship artwork, standard and Warbond values, savings, and feed freshness.
- Added an Event Calendar tool with official CIG and Bar Citizen dates from StarCitizen-Info, agenda and location filters, in-app event sources, sharing, Calendar export, and an offline last-known-good feed.
- Added clearly labeled anticipated dates for nine major annual Star Citizen events, projected from their official 2025 month/day windows.

### Changed
- Opens the item-translation method chooser at full height so every explanation is immediately visible, with Cloud presented first as the blue primary choice and Local shown as a neutral grey alternative.
- Caches the Account profile-background choices locally and reuses them until the fleet inventory changes, avoiding repeated full-fleet grouping and sorting when Account is opened.
- Silently refreshes the hosted Hangar item translation dictionary whenever the app launches or returns to the foreground while a translated item language is selected; English skips the refresh entirely.
- Started the `1.0.9` release branch and release-note tracking for ongoing work.
- Set the app release metadata to version 1.0.9, build 45.
- Began the Early Access overhaul with a compact Settings status row and moved the profile badge preference into Manage Plans, while preserving existing StoreKit product IDs and saved entitlement keys so current access carries forward after updating.
- Removed duplicate lifetime-plan details from the Early Access status card so lifetime owners see one concise Lifetime Access line.
- Kept Manage Plans card fills and borders visible when expanding the sheet to full height.
- Shortened the Early Access notice by removing its redundant affiliation footer.
- Simplified the Early Access feature comparison labels and values for faster scanning.
- Reworded Manage Plans headings, restore controls, guidance, and StoreKit status messages to avoid purchase terminology.
- Clarified that Early Access support funds Hangar Express only, does not buy anything from CIG or RSI, and does not guarantee specific or continued app features.
- Reframed the Early Access status message around Hangar Express being free and supporter contributions being optional.
- Identified Hangar Express as open-source software in its legal disclaimer and removed the Official RSI Website link.
- Replaced the broken WBCCU store link with an in-app cart that clears the RSI cart through its authenticated cart mutation, verifies it is empty, prepares only the selected source-to-Warbond upgrades, and opens checkout inside Hangar Express.
- Simplified WBCCU deal cards by removing redundant availability and new-money labels and shortening the cart status text.
- Simplified the WBCCU footer to show only the feed's last-updated time above the cart controls.
- Hid WBCCU checkout controls for an empty cart and made them float at the bottom of the screen while the cart contains upgrades.
- Added a compact red Clear Cart action to the floating WBCCU checkout controls.
- Reorganized Tools into a compact two-column grid with icon tiles and concise titles.
- Added persistent drag reordering to the Tools grid after a deliberate one-second hold.
- Renamed the Tools grid entries with shorter, clearer English and Simplified Chinese labels.
- Moved cloud terminology generation into a durable background queue and made the app upload up to four batches in parallel, so catalog-term submissions finish quickly on the phone while generation and retry work continue in the cloud.
- Simplified the Cloud Review privacy message to clearly state that only text needing translation is uploaded and that uploads contain no personally identifiable information.
- Reduced Cloud Review upload latency by batching validated text for background processing and hiding the upload progress bar as soon as queueing completes.

### Fixed
- Unified RSI browser authentication for buy-back checkout, WBCCU checkout, device management, account actions, and visible checkout pages so HttpOnly launcher tokens are supplied consistently to navigation and scripted requests.
- Dismissed the refresh progress overlay one second after its final 100% completion update, instead of leaving a completed card visible while background refresh work finishes.
- Fixed valid RSI organizations appearing unavailable when launcher authentication omitted the username by resolving the citizen handle from the authenticated account menu, saving that identity for later refreshes, and retaining the last successfully loaded organization during temporary lookup failures.
- Fixed intermittent signed-out WBCCU checkout pages by carrying the freshly prepared RSI session into the in-app browser, verifying WebKit retained its cookies, and attaching them to the first cart request.
- Moved on-device translation cache encoding and atomic file writes off the main thread, coalesced intermediate saves, and added ordered completion and background flushes so large hangars stay responsive without changing existing cache data.
- Fixed tool reordering so the selected icon follows the drag while surrounding icons animate into place, instead of lifting the entire Tools section.
- Fixed the dragged tool remaining enlarged after release and removed animation lag from finger tracking. Tool tiles now grow throughout the full one-second hold, provide a haptic cue when reordering activates, use a scroll-cooperative recognizer before activation, and disable page scrolling while an icon is being dragged.
- Fixed Logged-In Device Management for valid RSI sessions whose authentication cookies are HttpOnly by supplying the native session tokens to device requests, while treating RSI's HTTP 200 `ErrNotAuthenticated` response as an expired session that requires sign-in.

## v1.0.8 (In Progress)

### Added
- Added the ability to request an RSI character repair from Hangar Express when an account is eligible.
- Added left-swipe CCU exclusions to the calculator, with immediate path recalculation and an option to restore excluded upgrades.
- Added image export actions to save or share complete CCU calculations, plus a direct Save to Photos action for Hangar share pictures.

### Changed
- Made ship selection feel smoother in the CCU calculator.
- Simplified the CCU calculator summary to clearly show destination MSRP, melt value, total savings, and the payment breakdown.
- Renamed the untranslated Item Language option from Original to English.
- Standardized displayed dates as MM/DD/YYYY in English and YYYY/MM/DD in Simplified Chinese.
- Made Hangar and Fleet images appear sooner while scrolling quickly.
- Changed Hangar Log so it opens right away and starts showing entries in groups of 10 as they load.

### Fixed
- Fixed CCU calculator totals so the source ship is valued at its owned melt value, or MSRP when it is not owned, and added a value choice when owned copies have different melt values.
- Fixed Early Access renewal and auto-renewal details getting stuck on Checking until Manage Plans was opened.
- Fixed Hangar Log refreshes that could look empty or frozen while entries were still loading.
- Reduced app slowdown during Hangar Log refreshes.

## v0.5 (In Progress)

### Changed
- Moved active development onto the `v0.5` branch for the next round of account-page polish.
- Removed the account profile card's top-right organization and email icons for a cleaner presentation.
- Updated the account profile card to use the highest-MSRP owned ship with a known value as a cropped background image.
- Added a profile-card background picker so each account can save any owned ship as its preferred card background, with an automatic highest-MSRP fallback.

### Fixed
- Stopped Fleet from silently dropping unmatched ship entries when the hosted catalog cannot identify an exact ship variant, which restores missing capitals like some Idris pledges.
- Improved legacy fleet ship matching so older RSI names like `Idris-M Frigate`, `Idris-P Frigate`, `Mk1`, and older Hornet variants that omit `Super` now resolve to hosted MSRP, thumbnails, and full manufacturer names when the catalog has them.
- Changed `Clear Local Cache` to warn that a full reload is required, then clear cached snapshots and images before immediately rebuilding the live account data.
- Changed expired or missing RSI session cookies to trigger a dedicated re-login flow instead of a generic refresh failure, while keeping cached data visible when possible.

## v0.4 (In Progress)

### Added
- Added a stronger unofficial-app warning to the login screen so users see that Hangar Express is not an official RSI app before signing in.

### Changed
- Replaced the custom repository license file with an all-rights-reserved setup plus a separate limited personal-use permissions notice.
- Clarified the legal copy to state that Star Citizen, Squadron 42, RSI, and related game content shown by the app belong to the Cloud Imperium group of companies and their respective owners.

## v0.3 (In Progress)

### Added
- Added RSI store credit to the account snapshot when the live session exposes a logged-in account balance.
- Added a legal settings section plus repository disclaimer and custom personal-use license documents.

### Fixed
- Changed the account snapshot so the main value now shows current value and the smaller sublabel shows melt value.
- Tightened the account snapshot into a denser two-column layout so the extra summary cards fit more cleanly.
- Stopped live current-value totals from always mirroring melt by using the hosted ship MSRP feed for ship and CCU-based packages when available.
- Improved live store-credit retrieval by opening the top-right account avatar panel and reading the Store Credit row directly.
- Moved ship MSRP and CCU actual-value enrichment off the in-app RSI storefront flow and onto the hosted `ships.json` catalog.
- Persisted the last synced hangar snapshot on disk so normal build-to-build app updates can reopen cached data without forcing an immediate live reload.
- Fixed Fleet so unmatched FPS equipment no longer shows up under `Unknown`, and `GREY` catalog items now group under `Grey's Market`.
- Grouped duplicate ships in Fleet into counted rows so identical ships do not render multiple separate entries.
- Changed grouped hangar and fleet rows to show per-item values instead of reading like combined totals.
- Removed the always-zero recovered-value line from Buy Back rows to keep that list cleaner.
- Switched store-credit retrieval away from brittle avatar-popover scraping to RSI's structured `accountDashboard` credits data, with the side panel kept as a fallback path.
- Fixed store-credit normalization so RSI's structured balance now treats the last two digits as cents instead of whole dollars.

## v0.2 (In Progress)

### Added
- Started the `v0.2` release branch and patch notes tracking for ongoing work.
- Added a new `Account` tab to hold account-specific summary information.
- Added multi-account session storage so multiple RSI logins, cookies, and saved credentials persist in Keychain at the same time.
- Added an account switcher in `Settings` with one-tap switching plus an `Add Another Account` flow.
- Added saved-account buttons on the login screen so stored RSI sessions can be reopened without typing credentials again.
- Added a searchable buy-back list with search-activated quick filters for skins, ships, packages, and upgrades.

### Fixed
- Updated the RSI verification code field to accept letters and numbers instead of a numbers-only keyboard.
- Normalized verification codes to uppercase alphanumeric characters while typing so RSI email codes paste cleanly.
- Moved the hangar snapshot summary out of the `Hangar` tab and into the new `Account` tab.
- Moved `Settings` behind an account-screen toolbar button instead of keeping it as a standalone tab.
- Added common hangar search filters for `LTI`, `Upgrades`, and multi-ship `Packages`.
- Migrated older single-account saved sessions forward automatically so existing users keep their current cookies after upgrading.
- Hid the hangar’s common search filters until the search bar is active so the list stays cleaner when not searching.
- Fixed live hangar refresh so short pledge pages no longer get treated as the last page before the full hangar is synced.
- Raised the live RSI pagination safety limits and stopped silently truncating very large hangars mid-refresh.
- Grouped exact duplicate hangar items into counted rows while still keeping near-matches, like giftable versus locked copies, separated.
- Fixed missing hangar thumbnails for flair and other single-item pledges by using RSI’s pledge-card thumbnail instead of only item-detail images.
