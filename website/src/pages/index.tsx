import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import useBaseUrl from '@docusaurus/useBaseUrl';
import Layout from '@theme/Layout';
import styles from './index.module.css';

type Feature = {
  title: string;
  body: string;
};

const features: Feature[] = [
  {
    title: 'Real IMAP and SMTP',
    body: 'Mailbox discovery, unread counts, flags, move and delete, plus multipart sending with attachments — straight to your provider.',
  },
  {
    title: 'No middleman',
    body: 'There is no proxy, no account server, and no telemetry. Mailr talks directly to the servers you already trust.',
  },
  {
    title: 'Native SwiftUI',
    body: 'One SwiftUI codebase for iPhone, iPad, and Mac. iPhone-first navigation, three-column layouts on larger screens.',
  },
  {
    title: 'A safe HTML reader',
    body: 'JavaScript disabled, a strict CSP, a non-persistent data store, and remote images blocked until you ask for them.',
  },
  {
    title: 'A real MIME engine',
    body: 'Multipart trees, base64 and quoted-printable, RFC 2047 words, RFC 2231 filenames, charset conversion, inline images.',
  },
  {
    title: 'Try before you sign in',
    body: 'A seeded offline mailbox with attachments, HTML mail, drafts, and sent mail. Changes reset when you quit.',
  },
];

export default function Home(): ReactNode {
  const {siteConfig} = useDocusaurusContext();
  const heroShot = useBaseUrl('/img/screens/ios-inbox.png');
  const gallery = [
    {
      src: useBaseUrl('/img/screens/ios-message.png'),
      alt: 'Reading a message on iPhone',
      caption: 'Reader',
    },
    {
      src: useBaseUrl('/img/screens/ios-compose.png'),
      alt: 'Composing a message on iPhone',
      caption: 'Compose',
    },
    {
      src: useBaseUrl('/img/screens/ipad-message.png'),
      alt: 'Three-column message view on iPad',
      caption: 'iPad split view',
      wide: true,
    },
    {
      src: useBaseUrl('/img/screens/ios-dark-message.png'),
      alt: 'Dark mode message view on iPhone',
      caption: 'Dark mode',
    },
  ];

  return (
    <Layout
      title="Native mail for iPhone, iPad, and Mac"
      description={siteConfig.tagline}>
      <header className={styles.hero}>
        <div className={styles.heroGlow} aria-hidden="true" />
        <div className="container">
          <div className={styles.heroInner}>
            <div className={styles.heroCopy}>
              <span className={styles.badge}>
                Native SwiftUI · iOS 17+ · macOS 14+
              </span>
              <h1 className={styles.heroTitle}>
                Mail, without the <span>middleman</span>.
              </h1>
              <p className={styles.heroSubtitle}>
                Mailr is a privacy-first mail client for iPhone and iPad, with a
                macOS build from the same codebase. It speaks IMAP and SMTP
                directly — no proxy, no account server, no telemetry.
              </p>
              <div className={styles.heroActions}>
                <Link
                  className="button button--primary button--lg"
                  to="/docs/getting-started">
                  Get started
                </Link>
                <Link
                  className="button button--outline button--lg"
                  href="https://github.com/403access/mailr">
                  View on GitHub
                </Link>
              </div>
              <p className={styles.heroNote}>
                No third-party dependencies. Only Apple frameworks.
              </p>
            </div>
            <div className={styles.heroArt}>
              <div className={styles.phone}>
                <img src={heroShot} alt="Mailr inbox on iPhone" />
              </div>
            </div>
          </div>
        </div>
      </header>

      <main>
        <section className={styles.features}>
          <div className="container">
            <div className={styles.sectionHead}>
              <h2>Everything you expect from mail</h2>
              <p>
                Built as a real client, not a wrapper around a web inbox.
              </p>
            </div>
            <div className={styles.featureGrid}>
              {features.map((feature) => (
                <article className={styles.featureCard} key={feature.title}>
                  <h3>{feature.title}</h3>
                  <p>{feature.body}</p>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.gallery}>
          <div className="container">
            <div className={styles.sectionHead}>
              <h2>Designed for the way you read</h2>
              <p>
                Mailboxes in a slide-in drawer on iPhone, a three-column split
                view on iPad and Mac.
              </p>
            </div>
            <div className={styles.galleryGrid}>
              {gallery.map((shot) => (
                <figure
                  className={clsx(
                    styles.shot,
                    shot.wide && styles.shotWide,
                  )}
                  key={shot.caption}>
                  <img src={shot.src} alt={shot.alt} loading="lazy" />
                  <figcaption>{shot.caption}</figcaption>
                </figure>
              ))}
            </div>
          </div>
        </section>

        <section className={styles.cta}>
          <div className="container">
            <div className={styles.ctaInner}>
              <div>
                <h2>Read the docs, then build it</h2>
                <p>
                  Requirements, account setup, architecture notes, and the
                  security model — all in one place.
                </p>
              </div>
              <div className={styles.ctaActions}>
                <Link
                  className="button button--primary button--lg"
                  to="/docs/">
                  Browse documentation
                </Link>
                <Link
                  className="button button--secondary button--lg"
                  href="https://github.com/403access/mailr">
                  Clone the repo
                </Link>
              </div>
            </div>
          </div>
        </section>
      </main>
    </Layout>
  );
}
