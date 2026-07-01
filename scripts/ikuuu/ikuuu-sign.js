// ==UserScript==
// @name         iKuuu每日签到
// @namespace    http://tampermonkey.net/
// @version      1.0
// @description  每天自动打开 iKuuu 用户页，并在页面加载完成后自动点击签到按钮。
// @author       Gemini
// @match *://*/*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_openInTab
// @grant        GM_log
// @run-at       document-start
// @license      MIT
// ==/UserScript==

(function() {
    'use strict';

    const SIGN_IN_URL = 'https://ikuuu.org/user';
    const SIGN_IN_HOST = 'ikuuu.org';
    const SIGN_IN_PATH = '/user';
    const CHECKIN_SELECTOR = '#checkin-div a';
    const LOG_PREFIX = '[触发式自动签到]';

    const KEY_PREFIX = 'ikuuu_daily_sign_';
    const KEY_OPENED_DATE = KEY_PREFIX + 'opened_date';
    const KEY_CLICKED_DATE = KEY_PREFIX + 'clicked_date';

    main().catch((error) => {
        GM_log(`${LOG_PREFIX} 执行失败: ${error && error.message ? error.message : error}`);
    });

    async function main() {
        if (window.top !== window.self) return;

        const today = getToday();

        if (isSignInPage()) {
            await clickCheckinOnce(today);
            return;
        }

        await openSignInPageOnce(today);
    }

    async function openSignInPageOnce(today) {
        const clickedDate = await GM_getValue(KEY_CLICKED_DATE, '');
        const openedDate = await GM_getValue(KEY_OPENED_DATE, '');

        GM_log(`${LOG_PREFIX} 当前页面: ${window.location.href}`);
        GM_log(`${LOG_PREFIX} 今天: ${today}, 上次打开: ${openedDate}, 上次点击: ${clickedDate}`);

        if (clickedDate === today || openedDate === today) {
            GM_log(`${LOG_PREFIX} 今天已经触发过，无需再次打开。`);
            return;
        }

        await GM_setValue(KEY_OPENED_DATE, today);
        GM_openInTab(SIGN_IN_URL, { active: false, insert: true, setParent: true });
        GM_log(`${LOG_PREFIX} 已在后台打开签到页面: ${SIGN_IN_URL}`);
    }

    async function clickCheckinOnce(today) {
        const clickedDate = await GM_getValue(KEY_CLICKED_DATE, '');

        if (clickedDate === today) {
            GM_log(`${LOG_PREFIX} 今天已经点击过签到按钮。`);
            return;
        }

        await waitForPageLoaded();

        const button = await waitForElement(CHECKIN_SELECTOR, 30000);
        if (!button) {
            GM_log(`${LOG_PREFIX} 页面已加载，但未找到签到按钮: ${CHECKIN_SELECTOR}`);
            return;
        }

        GM_log(`${LOG_PREFIX} 找到签到按钮，准备点击。`);
        button.click();
        await GM_setValue(KEY_CLICKED_DATE, today);
        GM_log(`${LOG_PREFIX} 已点击签到按钮，并记录今日已触发。`);
    }

    function isSignInPage() {
        return location.protocol === 'https:'
            && location.hostname === SIGN_IN_HOST
            && normalizePath(location.pathname) === SIGN_IN_PATH;
    }

    function normalizePath(pathname) {
        return pathname.replace(/\/+$/, '') || '/';
    }

    function getToday() {
        const now = new Date();
        const year = now.getFullYear();
        const month = String(now.getMonth() + 1).padStart(2, '0');
        const day = String(now.getDate()).padStart(2, '0');

        return `${year}-${month}-${day}`;
    }

    function waitForPageLoaded() {
        if (document.readyState === 'complete') {
            return Promise.resolve();
        }

        return new Promise((resolve) => {
            window.addEventListener('load', resolve, { once: true });
        });
    }

    function waitForElement(selector, timeoutMs) {
        const existing = document.querySelector(selector);
        if (existing) return Promise.resolve(existing);

        return new Promise((resolve) => {
            const observer = new MutationObserver(() => {
                const element = document.querySelector(selector);
                if (!element) return;

                clearTimeout(timer);
                observer.disconnect();
                resolve(element);
            });

            const timer = setTimeout(() => {
                observer.disconnect();
                resolve(null);
            }, timeoutMs);

            observer.observe(document.documentElement, {
                childList: true,
                subtree: true
            });
        });
    }

})();
