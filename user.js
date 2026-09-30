// Firefox user.js — applied at every startup, no enterprise-policy support
// required. Used instead of policies.json because the container's autoconfig
// (autoconfig.js / mozilla.cfg) prevents policies.json from taking effect.
//
// This box has 1 GB RAM and 512 MB of host swap on LXC (no swapon possible),
// and Firefox must stream video through it. Memory is the binding constraint,
// so these cut process count and per-process overhead hard.

user_pref("fission.autostart", false);
user_pref("privacy.file_unique_origin", false);
user_pref("dom.ipc.processCount", 1);
user_pref("extensions.webextensions.remote", false);

user_pref("browser.newtabpage.enabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.page", 0);
user_pref("browser.startup.homepage", "about:blank");

user_pref("browser.tabs.memoryBudget.enabled", true);
user_pref("browser.tabs.memoryBudget.lowValue", 64);
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("dom.min_background_timeout_value", 10000);

user_pref("browser.cache.memory.enable", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("toolkit.startup.max_resumed_crashes", -1);
user_pref("browser.sessionstore.max_tabs_undo", 0);

user_pref("network.prefetch-next", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.predictor.enabled", false);

user_pref("dom.webnotifications.enabled", false);
user_pref("dom.push.enabled", false);
user_pref("media.gmp-manager.updateEnabled", false);
user_pref("app.update.auto", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
