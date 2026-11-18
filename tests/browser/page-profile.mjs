// Geometry belongs to the replay environment, never to an application's SCM.
// Embed the bundled fonts so navigation cannot race a server or system font.
import fs from "node:fs";

export const viewport = Object.freeze({ width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
const font = name => fs.readFileSync(new URL(`fonts/${name}.woff2`, import.meta.url)).toString("base64");
const stylesheet = `
@font-face { font-family: SignalsSpec; src: url(data:font/woff2;base64,${font("ibm-plex-sans-400")}) format('woff2'); font-weight: 100 900; }
@font-face { font-family: SignalsSpecMono; src: url(data:font/woff2;base64,${font("ibm-plex-mono-400")}) format('woff2'); font-weight: 100 900; }
html { font-family: SignalsSpec; font-size: 16px; }
button, input, select, textarea { font-family: SignalsSpec; }
* { scrollbar-width: none; }
::-webkit-scrollbar { width: 0; height: 0; }
`;

// Install before navigation. The early observer covers documents with no head
// yet, and the init script repeats for every cross-document app navigation.
export async function configureSpecPage(page) {
  // An actionable spec page is the foreground target. Some headless builds
  // stop animation frames in background tabs, even though CDP still runs JS.
  await page.send("Page.bringToFront");
  await page.send("Emulation.setDeviceMetricsOverride", viewport);
  await page.send("Page.setFontFamilies", { fontFamilies: {
    standard: "SignalsSpec", serif: "SignalsSpec", sansSerif: "SignalsSpec", fixed: "SignalsSpecMono",
  } });
  await page.send("Page.setFontSizes", { fontSizes: { standard: 16, fixed: 13 } });
  await page.evaluateOnNewDocument(css => {
    const install = () => {
      if (!document.documentElement) return false;
      const style = document.createElement("style");
      style.dataset.signalsSpecProfile = "";
      style.textContent = css;
      (document.head ?? document.documentElement).append(style);
      return true;
    };
    if (!install()) {
      const observer = new MutationObserver(() => { if (install()) observer.disconnect(); });
      observer.observe(document, { childList: true, subtree: true });
    }
  }, stylesheet);
}

// A missing font fails the replay instead of silently using platform fallback.
export async function readySpecPage(page) {
  await page.evaluate(async () => {
    for (const family of ["SignalsSpec", "SignalsSpecMono"]) {
      const loaded = await document.fonts.load(`16px ${family}`);
      if (loaded.length !== 1 || loaded[0].status !== "loaded") throw new Error(`spec font ${family} did not load`);
    }
    await document.fonts.ready;
  });
}
