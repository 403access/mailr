import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Mailr',
  tagline: 'A native, privacy-first mail client for iPhone, iPad, and Mac.',
  favicon: 'img/favicon.png',

  url: 'https://403access.github.io',
  baseUrl: '/mailr/',

  organizationName: '403access',
  projectName: 'mailr',
  trailingSlash: true,

  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl: 'https://github.com/403access/mailr/tree/main/website/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/screens/ios-inbox.png',
    colorMode: {
      defaultMode: 'light',
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'Mailr',
      logo: {
        alt: 'Mailr app icon',
        src: 'img/icon.png',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docs',
          position: 'left',
          label: 'Documentation',
        },
        {
          href: 'https://github.com/403access/mailr',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {label: 'Overview', to: '/docs/'},
            {label: 'Getting started', to: '/docs/getting-started'},
            {label: 'Architecture', to: '/docs/architecture'},
          ],
        },
        {
          title: 'Project',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/403access/mailr',
            },
            {
              label: 'Issues',
              href: 'https://github.com/403access/mailr/issues',
            },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'Security & privacy',
              to: '/docs/security',
            },
            {
              label: 'Limitations',
              to: '/docs/limitations',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Mailr. Built with Docusaurus.`,
    },
    prism: {
      additionalLanguages: ['swift', 'bash', 'json', 'yaml'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
