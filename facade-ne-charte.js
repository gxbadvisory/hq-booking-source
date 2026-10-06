
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
    // Textes que le moteur laisse en anglais : heures 12 h, messages de validation, emoji du bouton.
    const regles = [
      [/\b(\d{1,2}):(\d{2})\s?(AM|PM)\b/g, (_, h, m, p) => String((+h % 12) + (p === "PM" ? 12 : 0)).padStart(2, "0") + ":" + m],
      [/\s*🎆/g, ""],
      [/^Email is required$/, "L'adresse email est obligatoire."],
      [/^Email exceeds maximum length \((\d+) characters\)$/, "Adresse email trop longue ($1 caractères au maximum)."],
      [/^Email (format is invalid.*|domain is missing|domain format is invalid|username is missing|must be a text value)$/, "Adresse email invalide."],
      [/^Name (is required|cannot be blank)$/, "Le nom est obligatoire."],
      [/^Name is too short \(minimum (\d+) characters\)$/, "Nom trop court ($1 caractères au minimum)."],
      [/^Name is too long \(maximum (\d+) characters\)$/, "Nom trop long ($1 caractères au maximum)."],
      [/^Name contains invalid characters$/, "Le nom contient des caractères non autorisés."],
      [/^Name cannot be only numbers$/, "Le nom ne peut pas contenir que des chiffres."],
      [/^Name contains excessive whitespace$/, "Le nom contient trop d'espaces."],
      [/^Name must be a text value$/, "Nom invalide."],
      [/^(Message|Text) (is required|cannot be blank)$/, "Le message est obligatoire."],
      [/^(Message|Text) is too short \(minimum (\d+) characters\)$/, "Message trop court ($2 caractères au minimum)."],
      [/^(Message|Text) is too long \(maximum (\d+) characters\)$/, "Message trop long ($2 caractères au maximum)."],
      [/^Message must contain meaningful content$/, "Merci de préciser votre message."],
      [/^(Message|Text) must be a text value$/, "Message invalide."],
    ];
    const traduire = (racine) => {
      const marche = d.createTreeWalker(racine, NodeFilter.SHOW_TEXT);
      for (let n = marche.nextNode(); n; n = marche.nextNode()) {
        const avant = n.nodeValue, brut = avant.trim();
        if (!brut || brut.length > 160) continue;
        let apres = avant;
        for (const [motif, rempl] of regles) {
          apres = motif.source.startsWith("^") ? (motif.test(apres.trim()) ? apres.trim().replace(motif, rempl) : apres) : apres.replace(motif, rempl);
        }
        if (apres !== avant) n.nodeValue = apres;
      }
    };
    const surveiller = () => {
      traduire(d.body);
      new MutationObserver((ms) => {
        for (const m of ms) {
          if (m.type === "characterData") traduire(m.target.parentNode || d.body);
          else m.addedNodes.forEach((x) => (x.nodeType === 1 || x.nodeType === 3) && traduire(x.nodeType === 3 ? x.parentNode : x));
        }
      }).observe(d.body, { childList: true, subtree: true, characterData: true });
    };
    d.body ? surveiller() : d.addEventListener("DOMContentLoaded", surveiller);
    const titre = () => { if (d.title !== "Prendre rendez-vous · Nouvelles Entreprises") d.title = "Prendre rendez-vous · Nouvelles Entreprises"; };
    titre();
    new MutationObserver(titre).observe(d.head, { childList: true, subtree: true, characterData: true });
  } catch (e) {}
})();
