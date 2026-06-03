-- ════════════════════════════════════════════════════════════════════
-- OniMarketer — Phase 1 : schéma complet (tables om_*)
-- ════════════════════════════════════════════════════════════════════
-- Projet Supabase : kxdxxhepewziazfnfnkq (partagé avec OniPilote, OniCompta…)
-- Préfixe `om_` pour distinguer les tables OniMarketer.
--
-- À EXÉCUTER : Dashboard Supabase → SQL Editor → coller ce fichier → Run.
-- Idempotent : peut être exécuté plusieurs fois sans erreur.
--
-- Modules couverts par cette migration :
--   · Leads          → om_leads
--   · Apporteurs     → om_apporteurs
--   · Commissions    → om_commissions
--   · Parrainage     → om_parrains + om_filleuls
--   · Détection      → om_radar_signaux
--   · SEO local      → om_seo_pages
-- ════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────
-- 1. LEADS — pipeline de capture, alimenté par tous les canaux
--    (Configurateur, Simulateur, Formulaires, Apporteurs, Chatbot, etc.)
-- ────────────────────────────────────────────────────────────────────
-- ────────────────────────────────────────────────────────────────────
-- 1. APPORTEURS — réseau d'apport (agents immo, courtiers, parrains…)
--    Créé EN PREMIER car om_leads et om_commissions le référencent.
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_apporteurs (
  id          BIGSERIAL PRIMARY KEY,
  owner_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nm          TEXT NOT NULL,
  org         TEXT,                       -- organisation (ex: 'Century 21 Vannes')
  type        TEXT NOT NULL,              -- 'Agent immo', 'Courtier prêt', 'Mandataire', 'Notaire', 'Client parrain', 'Indépendant'
  tel         TEXT,
  email       TEXT,
  com         TEXT,                       -- accord commission ex: '1.0 %', '500 €/signature'
  status      TEXT NOT NULL DEFAULT 'actif', -- 'actif', 'inactif'
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_om_apporteurs_owner ON om_apporteurs(owner_id);

-- ────────────────────────────────────────────────────────────────────
-- 2. LEADS — pipeline de capture, alimenté par tous les canaux
--    (Configurateur, Simulateur, Formulaires, Apporteurs, Chatbot, etc.)
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_leads (
  id            BIGSERIAL PRIMARY KEY,
  owner_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  email         TEXT,
  tel           TEXT,
  src           TEXT,                      -- source : 'Configurateur', 'Simulateur PTZ', 'Google Ads'…
  bud           TEXT,                      -- budget : '< 200 k€', '200–300 k€'…
  zone          TEXT,                      -- ex : 'Maison 120 m² — Vannes'
  stage         TEXT NOT NULL DEFAULT 'new', -- 'new', 'cont', 'qual', 'rdv', 'sign', 'lost'
  score         INTEGER,                   -- lead scoring 0-100 (alimenté par module Score)
  apporteur_id  BIGINT REFERENCES om_apporteurs(id) ON DELETE SET NULL,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_om_leads_owner ON om_leads(owner_id);
CREATE INDEX IF NOT EXISTS idx_om_leads_stage ON om_leads(owner_id, stage);

-- ────────────────────────────────────────────────────────────────────
-- 3. COMMISSIONS — dues au réseau d'apporteurs
--    Une commission est liée à un apporteur ET (potentiellement) à un lead
--    signé. Le statut passe de 'à verser' à 'payée' au déblocage.
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_commissions (
  id              BIGSERIAL PRIMARY KEY,
  owner_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  apporteur_id    BIGINT NOT NULL REFERENCES om_apporteurs(id) ON DELETE CASCADE,
  lead_id         BIGINT REFERENCES om_leads(id) ON DELETE SET NULL,
  client_name     TEXT NOT NULL,         -- snapshot du nom client (au cas où lead est supprimé)
  ccmi_amount     INTEGER NOT NULL,      -- montant CCMI en euros (entiers)
  com_amount      INTEGER NOT NULL,      -- commission calculée en euros
  deblocage_date  DATE,                  -- date prévue de déblocage des fonds
  status          TEXT NOT NULL DEFAULT 'à verser', -- 'à verser', 'payée'
  paid_date       DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_om_commissions_owner ON om_commissions(owner_id);
CREATE INDEX IF NOT EXISTS idx_om_commissions_status ON om_commissions(owner_id, status);

-- ────────────────────────────────────────────────────────────────────
-- 4. PARRAINS — clients livrés qui parrainent
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_parrains (
  id              BIGSERIAL PRIMARY KEY,
  owner_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  client_name     TEXT NOT NULL,
  livraison_date  DATE,
  ref_code        TEXT UNIQUE NOT NULL,  -- code court ex 'MARCHND-7K3' pour le lien d'invitation
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_om_parrains_owner ON om_parrains(owner_id);

-- ────────────────────────────────────────────────────────────────────
-- 5. FILLEULS — leads issus d'un parrainage (lien parrain → filleul)
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_filleuls (
  id          BIGSERIAL PRIMARY KEY,
  parrain_id  BIGINT NOT NULL REFERENCES om_parrains(id) ON DELETE CASCADE,
  owner_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nm          TEXT NOT NULL,
  etat        TEXT NOT NULL DEFAULT 'lien envoyé', -- 'lien envoyé', 'lien cliqué', 'visite agence', 'signé'
  prime       INTEGER NOT NULL DEFAULT 0,
  signed_date DATE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_om_filleuls_owner ON om_filleuls(owner_id);
CREATE INDEX IF NOT EXISTS idx_om_filleuls_parrain ON om_filleuls(parrain_id);

-- ────────────────────────────────────────────────────────────────────
-- 6. RADAR — signaux open data détectés (permis, DIA, mutations)
--    Alimenté par un cron/job qui interroge l'API DVF gratuite et
--    insère les signaux trouvés dans la zone d'activité de l'owner.
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_radar_signaux (
  id            BIGSERIAL PRIMARY KEY,
  owner_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type          TEXT NOT NULL,           -- 'Permis déposé', 'DIA', 'Terrain vendu'
  zone          TEXT NOT NULL,           -- ex: 'Vannes — quartier Conleau'
  signal_info   TEXT,                    -- description du signal
  terrain_size  TEXT,                    -- ex: '487 m²'
  score         INTEGER,                 -- score chaud/tiède/froid 0-100
  status        TEXT NOT NULL DEFAULT 'nouveau', -- 'nouveau', 'ignoré', 'converti'
  lead_id       BIGINT REFERENCES om_leads(id) ON DELETE SET NULL,
  source_url    TEXT,                    -- URL source data.gouv.fr / DVF
  detected_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  meta          JSONB                    -- payload brut de l'API (commune, coords…)
);
CREATE INDEX IF NOT EXISTS idx_om_radar_owner ON om_radar_signaux(owner_id);
CREATE INDEX IF NOT EXISTS idx_om_radar_status ON om_radar_signaux(owner_id, status);

-- ────────────────────────────────────────────────────────────────────
-- 7. SEO PAGES — pages locales générées (commune × prestation)
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS om_seo_pages (
  id          BIGSERIAL PRIMARY KEY,
  owner_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  ville       TEXT NOT NULL,
  mot_cle     TEXT NOT NULL,
  slug        TEXT NOT NULL,                -- URL slug ex 'construire-maison-vannes'
  title       TEXT,
  content     TEXT,                         -- contenu HTML généré par Mistral
  position    INTEGER,                      -- position Google (mise à jour par job manuel ou GSC)
  vues        INTEGER NOT NULL DEFAULT 0,
  leads       INTEGER NOT NULL DEFAULT 0,
  status      TEXT NOT NULL DEFAULT 'en attente', -- 'en attente', 'indexée', 'erreur'
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (owner_id, slug)
);
CREATE INDEX IF NOT EXISTS idx_om_seo_owner ON om_seo_pages(owner_id);

-- ════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — chaque user ne voit que SES propres données
-- ════════════════════════════════════════════════════════════════════

-- Activer RLS sur toutes les tables om_*
ALTER TABLE om_leads          ENABLE ROW LEVEL SECURITY;
ALTER TABLE om_apporteurs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE om_commissions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE om_parrains       ENABLE ROW LEVEL SECURITY;
ALTER TABLE om_filleuls       ENABLE ROW LEVEL SECURITY;
ALTER TABLE om_radar_signaux  ENABLE ROW LEVEL SECURITY;
ALTER TABLE om_seo_pages      ENABLE ROW LEVEL SECURITY;

-- Helper pour générer 4 policies (select/insert/update/delete) par table
-- en une fois. Toutes basées sur owner_id = auth.uid().
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'om_leads', 'om_apporteurs', 'om_commissions',
    'om_parrains', 'om_filleuls', 'om_radar_signaux', 'om_seo_pages'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "%s_owner_select" ON %I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "%s_owner_insert" ON %I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "%s_owner_update" ON %I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "%s_owner_delete" ON %I', t, t);

    EXECUTE format(
      'CREATE POLICY "%s_owner_select" ON %I FOR SELECT TO authenticated USING (owner_id = auth.uid())',
      t, t
    );
    EXECUTE format(
      'CREATE POLICY "%s_owner_insert" ON %I FOR INSERT TO authenticated WITH CHECK (owner_id = auth.uid())',
      t, t
    );
    EXECUTE format(
      'CREATE POLICY "%s_owner_update" ON %I FOR UPDATE TO authenticated USING (owner_id = auth.uid()) WITH CHECK (owner_id = auth.uid())',
      t, t
    );
    EXECUTE format(
      'CREATE POLICY "%s_owner_delete" ON %I FOR DELETE TO authenticated USING (owner_id = auth.uid())',
      t, t
    );
  END LOOP;
END $$;

-- ════════════════════════════════════════════════════════════════════
-- TRIGGER updated_at auto sur les tables qui en ont besoin
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION om_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['om_leads','om_apporteurs','om_commissions','om_seo_pages']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated ON %I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION om_set_updated_at()',
      t, t
    );
  END LOOP;
END $$;

-- ════════════════════════════════════════════════════════════════════
-- FIN — vérifier dans le dashboard Supabase :
--   · Tables : 7 nouvelles tables om_*
--   · Auth : RLS activée (cadenas vert dans Table Editor)
--   · Policies : 4 par table (28 au total)
-- ════════════════════════════════════════════════════════════════════
