
;(() => {
  // Habillage Nouvelles Entreprises, seulement sur l'adresse publique NE (06/10/2026).
  try {
    if (location.hostname !== "nouvelles-entreprises-rdv.vercel.app") return;
    const d = document;
    d.documentElement.classList.add("ne-charte");
    d.documentElement.lang = "fr";
    const lien = (attrs) => { const e = d.createElement("link"); Object.assign(e, attrs); d.head.appendChild(e); };
    lien({ rel: "stylesheet", href: "/assets/ne-charte.css" });
    lien({ rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" });
    lien({ rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Newsreader:opsz,wght@6..72,500;6..72,600&display=swap" });
    d.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]').forEach((l) => l.remove());
    lien({ rel: "icon", type: "image/svg+xml", href: "/assets/ne-favicon.svg" });
    const entete = () => {
      if (d.getElementById("ne-entete")) return;
      const h = d.createElement("div");
      h.id = "ne-entete";
      h.innerHTML = '<a href="https://nouvelles-entreprises.com" aria-label="Nouvelles Entreprises"><img src="/assets/ne-logo.svg" alt="Nouvelles Entreprises" width="190" height="44"></a>';
      d.body.prepend(h);
    };
    d.body ? entete() : d.addEventListener("DOMContentLoaded", entete);
    // « Réserver » reste désactivé tant que le serveur n'a pas validé les champs, ce qui n'arrive
    // qu'à la sortie d'un champ : un clic direct depuis le dernier champ était perdu. On valide
    // alors le champ en cours, puis on soumet dès que le bouton s'active (une seule fois).
    // Même chose pour « Étape suivante », activé seulement après la réponse du serveur au choix du créneau.
    let enAttente = false, parti = false;
    const marquer = () => { parti = true; };
    d.addEventListener("submit", marquer, true);
    d.addEventListener("click", (e) => { if (e.isTrusted && e.target.closest && e.target.closest(".action-button--primary")) marquer(); }, true);
    addEventListener("pointerdown", (e) => {
      if (enAttente) return;
      const b = d.elementsFromPoint(e.clientX, e.clientY).find((x) => x.matches && x.matches("button.action-button--primary"));
      if (!b || !b.disabled) return;
      const cle = b.id ? "#" + b.id : null;
      const texte = b.textContent.trim();
      enAttente = true;
      parti = false;
      const champ = d.activeElement;
      if (champ && champ.matches("input, textarea")) champ.blur();
      const debut = Date.now();
      const attendre = () => {
        if (parti) { enAttente = false; return; }
        const bouton = (cle && d.querySelector(cle)) || [...d.querySelectorAll("button.action-button--primary")].find((x) => x.textContent.trim() === texte);
        if (bouton && !bouton.disabled) { enAttente = false; bouton.click(); return; }
        if (Date.now() - debut > 4000) { enAttente = false; return; }
        setTimeout(attendre, 60);
      };
      setTimeout(attendre, 60);
    }, true);
    const titre = () => { if (d.title !== "Prendre rendez-vous · Nouvelles Entreprises") d.title = "Prendre rendez-vous · Nouvelles Entreprises"; };
    titre();
    new MutationObserver(titre).observe(d.head, { childList: true, subtree: true, characterData: true });
  } catch (e) {}
})();
