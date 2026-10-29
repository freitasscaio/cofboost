// Consentimento de cookies e Google Analytics (LGPD).
//
// O ID de medição fica no atributo data-ga-id da tag <script> que carrega este arquivo:
//   <script src="assets/consent.js" data-ga-id="G-XXXXXXXXXX" defer></script>
// Com o atributo vazio, nada acontece: sem banner, sem cookies, sem requisição ao Google.
//
// Com ID: o banner aparece até a pessoa escolher. O script do Google só é baixado depois
// de "Aceitar". "Recusar" tem o mesmo destaque. A escolha fica guardada neste navegador
// (localStorage, necessário para lembrar a decisão) e pode ser mudada pelo botão
// "Preferências de cookies" do rodapé; retirar o consentimento apaga os cookies _ga.
(function () {
  const script = document.currentScript;
  const GA_ID = ((script && script.dataset.gaId) || "").trim();
  if (!/^G-[A-Z0-9]{4,16}$/.test(GA_ID)) return;

  const KEY = "cofboost-consent";
  const VERSION = 1; // mude se a Política mudar o uso de cookies: todos verão o banner de novo
  let loaded = false;

  const read = () => { try { const v = JSON.parse(localStorage.getItem(KEY)); return v && v.version === VERSION ? v : null; } catch (e) { return null; } };
  const save = (analytics) => { try { localStorage.setItem(KEY, JSON.stringify({ version: VERSION, analytics, date: new Date().toISOString() })); } catch (e) { } };

  function loadAnalytics() {
    if (loaded) return;
    loaded = true;
    window.dataLayer = window.dataLayer || [];
    window.gtag = function () { window.dataLayer.push(arguments); };
    // Só medição: nada de anúncios, Google Signals ou personalização.
    window.gtag("consent", "default", { analytics_storage: "granted", ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" });
    window.gtag("js", new Date());
    window.gtag("config", GA_ID, { allow_google_signals: false, allow_ad_personalization_signals: false });
    const s = document.createElement("script");
    s.async = true;
    s.src = "https://www.googletagmanager.com/gtag/js?id=" + encodeURIComponent(GA_ID);
    document.head.appendChild(s);
  }

  function removeAnalyticsCookies() {
    const host = location.hostname, parts = host.split(".");
    const domains = ["", host, "." + host];
    if (parts.length > 2) domains.push("." + parts.slice(-2).join("."));
    document.cookie.split(";").map((c) => c.split("=")[0].trim()).filter((n) => /^_ga/.test(n)).forEach((name) => {
      domains.forEach((d) => { document.cookie = name + "=; Max-Age=0; path=/" + (d ? "; domain=" + d : ""); });
    });
  }

  // Banner
  const css = document.createElement("style");
  css.textContent = `
    .cookie-bar { position: fixed; z-index: 60; left: 16px; right: 16px; bottom: 16px; max-width: 760px; margin: 0 auto;
      background: #131a2b; border: 1px solid #2e3a5c; border-radius: 16px; padding: 18px 20px; color: #e6ebf5;
      box-shadow: 0 20px 50px -20px rgba(0,0,0,.7); font: 14.5px/1.6 Poppins, system-ui, sans-serif; }
    .cookie-bar p { margin: 0 0 14px; color: #c9d2e6; }
    .cookie-bar a { color: #a78bfa; }
    .cookie-bar .cookie-actions { display: flex; gap: 10px; flex-wrap: wrap; }
    .cookie-bar button { flex: 1 1 160px; padding: 11px 18px; border-radius: 10px; font: 600 14.5px Poppins, system-ui, sans-serif; cursor: pointer;
      background: #1c2540; color: #e6ebf5; border: 1px solid #34405e; }
    .cookie-bar button:hover { background: #253154; }
    .cookie-bar button:focus-visible { outline: 2px solid #a78bfa; outline-offset: 3px; }`;
  document.head.appendChild(css);

  function showBanner(focus) {
    if (document.querySelector(".cookie-bar")) return;
    const bar = document.createElement("section");
    bar.className = "cookie-bar";
    bar.setAttribute("aria-label", "Preferências de cookies");
    bar.innerHTML = `
      <p>Com o seu aceite, usamos o Google Analytics para contar visitas e entender quais páginas ajudam mais. Ele grava cookies
      e os dados são processados pelo Google, inclusive fora do Brasil (EUA). Nada é ativado se você recusar, e você pode mudar
      de ideia quando quiser em "Preferências de cookies", no rodapé. <a href="privacidade.html#analytics">Saiba mais</a>.</p>
      <div class="cookie-actions">
        <button type="button" data-choice="reject">Recusar</button>
        <button type="button" data-choice="accept">Aceitar</button>
      </div>`;
    bar.addEventListener("click", (e) => {
      const btn = e.target.closest("button[data-choice]");
      if (!btn) return;
      const accepted = btn.dataset.choice === "accept";
      const before = read();
      save(accepted);
      bar.remove();
      if (accepted) loadAnalytics();
      else if (before && before.analytics) { removeAnalyticsCookies(); location.reload(); } // para o Analytics que já estava rodando
    });
    document.body.appendChild(bar);
    if (focus) bar.querySelector("button").focus();
  }

  // Botão "Preferências de cookies" (no rodapé de cada página)
  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".js-cookie-prefs").forEach((b) => {
      b.hidden = false;
      b.addEventListener("click", () => showBanner(true));
    });
    const choice = read();
    if (!choice) showBanner(false);
  });
  const choice = read();
  if (choice && choice.analytics) loadAnalytics();
})();
