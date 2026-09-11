// ═══════════════════════════════════════════════════════════════════
// ONIQ PILOTAGE — la réception des leads
//
// Une adresse que l'on donne à un fournisseur (une place de marché, un
// comparateur de logiciels, le formulaire « Demander ma maquette » du
// site) pour qu'il dépose ses leads directement dans le CRM. Le lead
// arrive, la fiche se crée, elle remonte en tête de la
// session d'appels de son commercial. Le délai de rappel commence à
// courir à l'instant où le fournisseur a envoyé, pas quand quelqu'un
// a lu son courrier.
//
// Le fournisseur s'annonce avec le jeton affiché sur sa fiche dans
// l'écran Leads. Ce jeton est le nôtre : il ne donne accès à rien
// d'autre qu'au dépôt d'un lead.
// ═══════════════════════════════════════════════════════════════════

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const CLE_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const H = {
  apikey: CLE_SERVICE,
  Authorization: `Bearer ${CLE_SERVICE}`,
  "Content-Type": "application/json",
};

// Les fournisseurs ne nomment pas leurs champs de la même façon, et
// ils préfixent : Pharow écrit « positionEmail », « personFirstName »,
// « companyNafCode ». Chercher le nom exact ne suffit donc pas. On
// regarde en trois passes, de la plus sûre à la plus large : le nom
// exact, puis la fin du nom, puis le nom quelque part dedans.
//
// Une passe large peut attraper n'importe quoi — « positionEmailStatus »
// pour une adresse, par exemple. D'où le contrôle facultatif : un champ
// qui ne ressemble pas à ce qu'on cherche est ignoré, et la recherche
// continue.
function pioche(o: Record<string, unknown>, noms: string[],
                valide?: (s: string) => boolean): string {
  const cles = Object.keys(o);
  const norm = (k: string) => k.toLowerCase().replace(/[^a-z0-9]/g, "");
  const bon = (v: unknown): string => {
    if (v === null || v === undefined) return "";
    const s = String(v).trim();
    if (!s || s === "null" || s === "undefined" || s === "-") return "";
    if (valide && !valide(s)) return "";
    return s;
  };
  const passes: Array<(k: string, n: string) => boolean> = [
    (k, n) => norm(k) === n,
    (k, n) => norm(k).endsWith(n),
    (k, n) => norm(k).includes(n),
  ];
  for (const test of passes) {
    for (const n of noms) {
      for (const k of cles) {
        if (test(k, n)) { const v = bon(o[k]); if (v) return v; }
      }
    }
  }
  return "";
}
const EST_MAIL = (s: string) => /^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(s);
const EST_TEL = (s: string) => s.replace(/[^0-9]/g, "").length >= 9;

// Un fournisseur n'envoie pas toujours un objet plat. Pharow range la
// personne d'un côté et l'entreprise de l'autre ; d'autres emboîtent
// tout sous « data ». On aplatit donc l'arbre entier en une seule
// table de champs : ce qu'on cherche s'y trouve, quel que soit
// l'étage où il était rangé.
function aplatir(o: unknown, dans: Record<string, unknown> = {}, prof = 0): Record<string, unknown> {
  if (!o || typeof o !== "object" || prof > 5) return dans;
  for (const [k, v] of Object.entries(o as Record<string, unknown>)) {
    if (v === null || v === undefined) continue;
    if (Array.isArray(v)) {
      const s = v.find((x) => typeof x === "string" && String(x).trim());
      if (s !== undefined && !dans[k]) dans[k] = s;
      const o2 = v.find((x) => x && typeof x === "object");
      if (o2) aplatir(o2, dans, prof + 1);
    } else if (typeof v === "object") {
      aplatir(v, dans, prof + 1);
    } else if (dans[k] === undefined || String(dans[k]).trim() === "") {
      dans[k] = v;
    }
  }
  return dans;
}

// Un envoi peut porter un contact ou cent. On rend toujours une liste.
function lots(corps: unknown): unknown[] {
  if (Array.isArray(corps)) return corps;
  const o = corps as Record<string, unknown>;
  for (const k of ["prospects", "data", "items", "results", "records", "rows",
                   "contacts", "leads", "payload", "list", "lignes"]) {
    if (Array.isArray(o?.[k])) return o[k] as unknown[];
  }
  return [corps];
}

Deno.serve(async (req) => {
  const repond = (code: number, corps: unknown) =>
    new Response(JSON.stringify(corps), {
      status: code,
      headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
    });

  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "content-type,x-jeton",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
      },
    });
  }
  if (req.method !== "POST") return repond(405, { erreur: "POST attendu" });

  let brut: unknown = {};
  try {
    brut = await req.json();
  } catch {
    // Certains fournisseurs postent un formulaire plutôt que du JSON.
    try {
      const f = await req.formData();
      const o: Record<string, unknown> = {};
      f.forEach((v, k) => (o[k] = String(v)));
      brut = o;
    } catch {
      return repond(400, { erreur: "corps illisible" });
    }
  }
  const corps = aplatir(brut);

  // ── Qui dépose ? ────────────────────────────────────────────────
  const url = new URL(req.url);
  const jeton =
    req.headers.get("x-jeton") ??
    url.searchParams.get("jeton") ??
    String(corps.jeton ?? corps.token ?? "");
  if (!jeton) return repond(401, { erreur: "jeton absent" });

  const rs = await fetch(
    `${URL_BASE}/rest/v1/ls_sources?select=*&jeton=eq.${encodeURIComponent(jeton)}&limit=1`,
    { headers: H },
  );
  const sources = await rs.json();
  if (!Array.isArray(sources) || !sources.length) return repond(403, { erreur: "jeton inconnu" });
  const src = sources[0];

  // ── Un contact à la fois ────────────────────────────────────────
  // Le webhook peut en déposer un ou cent : on traite chaque ligne de
  // la même façon, et on rend un bilan plutôt que de s'arrêter à la
  // première qui coince.
  const url2 = new URL(req.url);
  async function traiter(corps: Record<string, unknown>): Promise<Record<string, unknown>> {
    const repond = (code: number, o: Record<string, unknown>) => ({ code, ...o });
  // ── Le lead ─────────────────────────────────────────────────────
    // Les graphies acceptées : françaises, anglaises, avec ou sans
    // séparateur. La comparaison efface tout ce qui n'est pas une
    // lettre, donc « company_name » et « companyName » se rejoignent.
    // Les noms de Pharow d'abord, puis les graphies courantes des
    // autres fournisseurs. Le premier trouvé gagne.
    const societe = pioche(corps, ["companyname", "companybrandname", "societe", "raisonsociale",
      "entreprise", "nomentreprise", "company", "companylegalname", "legalname",
      "organization", "organisation", "employer", "society", "nom", "name"]);
    const site = pioche(corps, ["companywebsite", "companywebsiteurl", "site", "siteweb",
      "website", "websiteurl", "url", "domaine", "domain", "companydomain"]);
    const siren = pioche(corps, ["companysiren", "siren", "companyhqsiret", "siret",
      "sirennumber", "registrationnumber"]);
    const metier = pioche(corps, ["companynafsector", "companyactivity", "metier", "activite",
      "secteur", "industry", "sector", "categorie", "category", "activity", "activitylabel"]);
    // Le code NAF, s'il est là : c'est lui qui range la fiche dans la
    // bonne campagne, sans que personne ait à choisir un lien plutôt
    // qu'un autre.
    // « 55.20Z » devient « 5520Z » : c'est sous cette forme que les
    // campagnes rangent leurs codes.
    const naf = pioche(corps, ["companynafcode", "naf", "codenaf", "ape", "codeape", "nafcode",
      "apecode", "nafape", "codenafape", "activitycode"])
      .toUpperCase().replace(/[^0-9A-Z]/g, "").slice(0, 5);
    const effectif = pioche(corps, ["companystaff", "companyheadcount", "companysize",
      "effectif", "effectifs", "salaries", "employees", "headcount", "taille",
      "employeecount", "staff", "tailleeffectif"]);
    const poste = pioche(corps, ["positionjobtitle", "poste", "fonction", "titre", "jobtitle",
      "title", "job", "role", "currentposition"]);
    // Le portable de la personne avant le standard de l'entreprise :
    // on préfère joindre quelqu'un plutôt qu'un accueil.
    const tel = pioche(corps, ["personmobilephone", "personmobilephonebettercontact",
      "personphonekaspr1", "personphonefullenrich1", "personphonekaspr3",
      "personphonefullenrich3", "companymainphone", "telephone", "tel", "phone", "mobile",
      "portable", "phonenumber", "mobilephone", "telephonenumber"], EST_TEL);
    // L'adresse nominative d'abord, l'adresse de standard en dernier
    // recours : la campagne écartera celle-ci d'elle-même, mais autant
    // que la fiche la porte pour l'appel.
    const email = pioche(corps, ["positionemail", "personemail", "emailpro",
      "emailprofessionnel", "professionalemail", "workemail", "businessemail",
      "email", "mail", "courriel", "emailaddress", "companygenericemail"], EST_MAIL);
    // Le nom du contact peut venir en un morceau ou en deux. On prend
    // ce qui existe, dans cet ordre, et on recolle si besoin.
    const prenom = pioche(corps, ["personfirstname", "prenom", "firstname", "givenname"]);
    const nomFamille = pioche(corps, ["personlastname", "nomdefamille", "nomfamille",
      "lastname", "familyname", "surname"]);
    const dirigeant = [prenom, nomFamille].filter(Boolean).join(" ")
      || pioche(corps, ["contact", "dirigeant", "nomcontact", "fullname",
        "prenomnom", "interlocuteur", "personname", "contactname"]);
    // Pharow écrit la ville sous la forme « Vannes (56000) » : le code
    // postal est dedans, on le récupère plutôt que de le perdre.
    const villeBrute = pioche(corps, ["companycity", "personcity", "ville", "city",
      "commune", "localite", "town"]);
    const cpDansVille = (/\((\d{5})\)/.exec(villeBrute) ?? [])[1] ?? "";
    const ville = villeBrute.replace(/\s*\(\d{5}\)\s*/, "").trim();
    const cp = pioche(corps, ["companypostalcode", "codepostal", "cp", "zip", "postalcode",
      "zipcode", "postcode"]) || cpDansVille;
    const besoin = pioche(corps, ["besoin", "message", "commentaire", "projet", "description", "demande"]);

    if (!societe && !tel && !email) {
      // Le plus utile ici n'est pas de refuser, c'est de dire ce qu'on
      // a reçu : les noms de champs du fournisseur suffisent à régler
      // le problème en une minute.
      return repond(400, { erreur: "ni société, ni téléphone, ni e-mail",
                           champs: Object.keys(corps).slice(0, 60) });
    }

    // ── Où ranger ? ─────────────────────────────────────────────────
    // Un fournisseur de leads vend des gens qui ont demandé un devis :
    // ils vont dans la file d'appels, à rappeler tout de suite. Un outil
    // de ciblage comme Pharow livre des entreprises qui n'ont rien
    // demandé : elles vont dans le fichier de prospection, celui que
    // lisent les campagnes et le recrutement de partenaires. Confondre
    // les deux, c'est appeler en urgence quelqu'un qui n'attend rien.
    const vers = String(url2.searchParams.get("vers") ?? corps.vers ?? src.destination ?? "leads")
      .toLowerCase();
    if (vers === "prospection" || vers === "partenaires") {
      // La maison peut être imposée par le lien : une même source de
      // ciblage sert les deux maisons, chacune avec son lien.
      const dem = String(url2.searchParams.get("activite") ?? "").toLowerCase();
      let activite = (dem === "tiimizy" || dem === "bornistes")
        ? dem
        : (src.activite === "les_deux" ? "bornistes" : src.activite);
      // L'étiquette du lien, s'il en porte une.
      let etiquette = String(url2.searchParams.get("metier") ?? "").trim();

      // ── La campagne imposée par le lien ───────────────────────────
      // Une adresse par campagne : la fiche entre là où on l'a dit,
      // quel que soit son code d'activité. C'est ce qu'il faut quand la
      // liste est construite sur un signal (une entreprise qui recrute,
      // qui ouvre un site) et non sur un secteur : ces entreprises ont
      // des codes NAF quelconques, et sans cela elles arriveraient au
      // fichier sans trouver de campagne.
      const dem2 = String(url2.searchParams.get("campagne") ?? "").trim();
      if (dem2) {
        try {
          const cs = await (await fetch(
            `${URL_BASE}/rest/v1/ls_campagnes?select=nom,activite,cible&modele=eq.${encodeURIComponent(dem2)}` +
            `&statut=in.(brouillon,programmee,en_cours)&order=cree_le.desc&limit=1`,
            { headers: H },
          )).json();
          const c = Array.isArray(cs) ? cs[0] : null;
          if (c) {
            activite = String(c.activite);
            // L'étiquette de campagne est dans son audience : on prend
            // la sienne plutôt que d'en inventer une qui ne filtrerait
            // rien.
            const l = (c?.cible?.types ?? []) as string[];
            etiquette = l.find((x) => String(x).startsWith("Pharow")) ?? `Pharow · ${c.nom}`;
          }
        } catch { /* pas de campagne imposée : on retombe sur le code NAF */ }
      }

      // ── Le rangement automatique ──────────────────────────────────
      // Une seule adresse sert les quatre campagnes : c'est le code NAF
      // de l'entreprise qui dit laquelle la cherche. On regarde les
      // campagnes vivantes, on prend la première dont le ciblage porte
      // ce code, et la fiche prend sa maison et son libellé de métier.
      // Sans code NAF ou sans campagne correspondante, la fiche entre
      // quand même au fichier : elle attendra qu'on la range.
      if (!etiquette && naf) {
        try {
          const cs = await (await fetch(
            `${URL_BASE}/rest/v1/ls_campagnes?select=activite,cible&statut=in.(brouillon,programmee,en_cours)&limit=50`,
            { headers: H },
          )).json();
          for (const c of (Array.isArray(cs) ? cs : [])) {
            const l = (c?.cible?.nafs ?? []) as Array<{ nom?: string; naf?: string }>;
            const t = l.find((x) => String(x?.naf ?? "").toUpperCase() === naf);
            if (t) { activite = String(c.activite); etiquette = String(t.nom ?? ""); break; }
          }
        } catch { /* pas de rangement : la fiche entre sans étiquette */ }
      }
      if (!etiquette) etiquette = metier || String(corps.metier_etiquette ?? "");
      // ── Déjà connue ? ───────────────────────────────────────────
      // La moisson gratuite a probablement déjà créé la fiche : elle
      // ratisse le registre entier. Ce qu'un fournisseur apporte alors
      // n'est pas l'entreprise, c'est l'adresse nominative du
      // dirigeant, que le registre ne donne jamais.
      //
      // On ne recrée donc rien, et surtout on n'écrase rien : une
      // fiche peut porter un historique d'appels, un refus, un
      // contrat. On ne remplit que les cases vides.
      let existante: Record<string, unknown> | null = null;
      async function chercher(q: string) {
        if (existante) return;
        try {
          const r = await fetch(
            `${URL_BASE}/rest/v1/ls_prescripteurs?select=*&activite=eq.${activite}&${q}&limit=1`,
            { headers: H });
          const l = await r.json();
          if (Array.isArray(l) && l[0]) existante = l[0];
        } catch { /* on tentera la création */ }
      }
      // Le SIREN d'abord : c'est la seule clé qui ne se réécrit pas
      // d'une source à l'autre.
      if (siren) await chercher(`siren=eq.${encodeURIComponent(siren)}`);
      if (email) await chercher(`email=ilike.${encodeURIComponent(email)}`);
      if (tel) await chercher(`tel=ilike.*${encodeURIComponent(tel.replace(/[^0-9]/g, "").slice(-9))}*`);

      if (existante) {
        const e = existante as Record<string, unknown>;
        const vide = (v: unknown) => !String(v ?? "").trim();
        const maj: Record<string, unknown> = {};
        if (email && vide(e.email)) {
          maj.email = email;
          maj.email_origine = dirigeant ? "personne" : "generique";
        }
        if (dirigeant && vide(e.contact)) maj.contact = [dirigeant, poste].filter(Boolean).join(" — ");
        if (tel && vide(e.tel)) maj.tel = tel;
        if (naf && vide(e.naf)) maj.naf = naf;
        if (effectif && vide(e.effectif)) maj.effectif = effectif;
        if (site && vide(e.site)) maj.site = site;
        if (etiquette && vide(e.type)) maj.type = etiquette;
        // Ce qui rend une fiche utilisable en campagne, c'est l'adresse.
        // Quand c'est le fournisseur qui la donne, c'est lui qui a fait
        // le travail : la source le dit, et la note garde la mémoire de
        // qui avait trouvé l'entreprise. C'est ce qui permettra de
        // comparer le fichier acheté et la moisson gratuite.
        if (maj.email) {
          maj.source = src.nom;
          maj.note = [String(e.note ?? ""),
            `Entreprise trouvée par ${String(e.source ?? "la moisson")}, adresse fournie par ${src.nom}.`]
            .filter((x) => String(x).trim()).join("\n");
        }
        if (!Object.keys(maj).length) return repond(200, { ok: true, deja: e.id });
        const up = await fetch(`${URL_BASE}/rest/v1/ls_prescripteurs?id=eq.${e.id}`, {
          method: "PATCH", headers: H, body: JSON.stringify(maj),
        });
        if (!up.ok) return repond(500, { erreur: (await up.text()).slice(0, 200) });
        await up.text().catch(() => "");
        return repond(200, { ok: true, complete: e.id, champs: Object.keys(maj) });
      }
      const fiche2 = {
        nom: societe || dirigeant || "Sans nom",
        activite,
        type: etiquette,
        contact: [dirigeant, poste].filter(Boolean).join(" — "),
        tel: tel || "",
        email: email || "",
        site: site || "",
        siren: siren || null,
        naf: naf || "",
        effectif: effectif || "",
        ville: [cp, ville].filter(Boolean).join(" "),
        code_postal: cp,
        // Une adresse livrée avec un nom de personne est une adresse
        // nominative : c'est ce qui fait la valeur d'un fichier acheté.
        email_origine: email ? (dirigeant ? "personne" : "generique") : "",
        statut: "A contacter",
        source: src.nom,
        note: besoin,
        owner_email: src.owner_email || "",
      };
      const cr2 = await fetch(`${URL_BASE}/rest/v1/ls_prescripteurs`, {
        method: "POST",
        headers: { ...H, Prefer: "return=representation,resolution=ignore-duplicates" },
        body: JSON.stringify(fiche2),
      });
      if (!cr2.ok) return repond(500, { erreur: await cr2.text() });
      const cree2 = await cr2.json().catch(() => []);
      return repond(200, { ok: true, prospection: true,
        id: Array.isArray(cree2) && cree2[0] ? cree2[0].id : null });
    }

    // ── Le doublon ──────────────────────────────────────────────────
    // Deux plateformes revendent le même formulaire : on rattache au lieu
    // de créer une deuxième fiche que deux commerciaux appelleraient.
    if (tel) {
      const dj = await fetch(
        `${URL_BASE}/rest/v1/ls_prospects?select=id,societe&tel=eq.${encodeURIComponent(tel)}&limit=1`,
        { headers: H },
      );
      const deja = await dj.json();
      if (Array.isArray(deja) && deja.length) {
        await fetch(`${URL_BASE}/rest/v1/ls_prospects?id=eq.${deja[0].id}`, {
          method: "PATCH",
          headers: H,
          body: JSON.stringify({
            prochaine: "RAPPELER — nouveau lead sur une fiche connue",
            rappel_le: new Date().toISOString(),
            note: [besoin, `Redéposé par ${src.nom} le ${new Date().toLocaleDateString("fr-FR")}`]
              .filter(Boolean).join("\n"),
          }),
        });
        return repond(200, { ok: true, rattache: deja[0].id });
      }
    }

    const fiche = {
      societe: societe || dirigeant || "Lead sans nom",
      activite: src.activite === "les_deux" ? "bornistes" : src.activite,
      tel: tel || null,
      email: email || null,
      dirigeant,
      ville: [cp, ville].filter(Boolean).join(" "),
      code_postal: cp,
      source: src.nom,
      est_lead: true,
      origine_lead: "formulaire",
      etape: "A contacter",
      owner_email: src.owner_email || "",
      note: besoin,
      prochaine: "RAPPELER TOUT DE SUITE",
      // Pas de rappel posé à la création. Un lead jamais appelé est
      // déjà en tête de sa file, trié du plus frais au plus ancien :
      // lui mettre en plus une date de rappel le faisait revenir
      // indéfiniment dans la file des rappels dus, même une fois
      // qualifié, parce qu'un rappel dû ne regarde pas le résultat
      // d'appel — et c'est normal, une promesse doit toujours revenir.
      // La date de rappel est donc réservée aux promesses faites à
      // quelqu'un.
    };

    const cr = await fetch(`${URL_BASE}/rest/v1/ls_prospects`, {
      method: "POST",
      headers: { ...H, Prefer: "return=representation" },
      body: JSON.stringify(fiche),
    });
    if (!cr.ok) return repond(500, { erreur: await cr.text() });
    const cree = await cr.json();

    await fetch(`${URL_BASE}/rest/v1/ls_activite`, {
      method: "POST",
      headers: H,
      body: JSON.stringify({
        acteur: src.nom,
        action: "lead.recu",
        cible: fiche.societe,
        cible_id: Array.isArray(cree) && cree[0] ? cree[0].id : null,
      }),
    });

    return repond(200, { ok: true, id: Array.isArray(cree) && cree[0] ? cree[0].id : null });

  }

  const lignes = lots(brut).map((x) => aplatir(x));
  const bilan = { traites: 0, crees: 0, completes: 0, deja: 0, refuses: 0 };
  const soucis: unknown[] = [];
  for (const l of lignes) {
    let r: Record<string, unknown>;
    try { r = await traiter(l); }
    catch (e) { r = { code: 500, erreur: String((e as Error).message ?? e).slice(0, 200) }; }
    bilan.traites++;
    if (Number(r.code) >= 400) { bilan.refuses++; if (soucis.length < 5) soucis.push(r); }
    else if (r.complete) bilan.completes++;
    else if (r.deja || r.rattache) bilan.deja++;
    else bilan.crees++;
  }
  // On répond 200 dès qu'une ligne est passée : un fournisseur qui
  // reçoit une erreur réessaie tout le lot, doublons compris.
  const code = bilan.crees || bilan.completes || bilan.deja ? 200 : 400;
  return repond(code, { ok: code === 200, ...bilan, soucis });
});
