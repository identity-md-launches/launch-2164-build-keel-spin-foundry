import type { CSSProperties } from "react";
export function Icon({ name, size = 20 }: { name: string; size?: number }) {
  const paths: Record<string, React.ReactNode> = {
    spin: (
      <>
        <path d="M20 9a8 8 0 1 0-1 8M20 3v6h-6" />
        <path d="m10 8 6 4-6 4Z" />
      </>
    ),
    history: (
      <>
        <path d="M4 6h16M4 12h11M4 18h7" />
        <circle cx="19" cy="18" r="3" />
      </>
    ),
    mine: (
      <>
        <circle cx="12" cy="8" r="4" />
        <path d="M5 21v-2a7 7 0 0 1 14 0v2" />
      </>
    ),
    info: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M12 11v6M12 7v1" />
      </>
    ),
    arrow: <path d="m7 17 10-10M7 7h10v10" />,
    chevron: <path d="m9 5 7 7-7 7" />,
    close: <path d="m6 6 12 12M6 18 18 6" />,
    check: <path d="m5 12 4 4L19 6" />,
    wallet: (
      <>
        <path d="M3 7V5a2 2 0 0 1 2-2h13v4M3 7h18v14H3Z" />
        <path d="M21 11h-6v6h6M17 14h1" />
      </>
    ),
    leaf: (
      <>
        <path d="M20 3C9 2 2 8 6 16c7 6 15-2 14-13ZM4 21 16 7M10 14l-1-5m1 5 6 1" />
      </>
    ),
    clock: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M12 7v5l3 2" />
      </>
    ),
  };
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name] ?? paths.leaf}
    </svg>
  );
}
export function Fawn({
  size = 76,
  style,
}: {
  size?: number;
  style?: CSSProperties;
}) {
  return (
    <svg
      style={style}
      className="fawn"
      width={size}
      height={size}
      viewBox="0 0 100 100"
      fill="none"
      aria-hidden="true"
    >
      <defs>
        <linearGradient
          id="chrome"
          x1="25"
          y1="18"
          x2="74"
          y2="86"
          gradientUnits="userSpaceOnUse"
        >
          <stop stopColor="#f0f5f1" />
          <stop offset=".26" stopColor="#85958b" />
          <stop offset=".48" stopColor="#e4eae6" />
          <stop offset=".72" stopColor="#64786b" />
          <stop offset="1" stopColor="#d3ded6" />
        </linearGradient>
      </defs>
      <path
        d="m58 29-5-14m4 7-8-3m16 9 5-16m-3 9 10-5"
        stroke="#bbc9bf"
        strokeWidth="2.5"
        strokeLinecap="round"
      />
      <path
        d="M57 31c-10-13-20-8-17-2 2 4 8 5 15 5m10-3c8-15 20-13 17-6-2 5-8 7-15 9"
        fill="url(#chrome)"
      />
      <path
        d="M29 51c-9 2-12-5-9-9m9 9c-13 21 0 28 6 28l-1 12h6l4-16 14 1 4 15h6l-4-24c12-14 7-21 6-31-1-12-19-12-18 2l-1 13c-8-3-15-3-22 0Z"
        fill="url(#chrome)"
        stroke="#c9d4cc"
        strokeWidth=".6"
      />
      <circle cx="64" cy="36" r="1.5" fill="#0b110e" />
      <path
        d="M78 51c-18-3-25 9-17 22 14-1 22-9 17-22Z"
        fill="#c9ddbf"
        stroke="#f0f5f1"
        strokeWidth="1.2"
      />
      <path
        d="m60 75 13-18m-7 9-1-6m1 6 7-1"
        stroke="#47634d"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}
export function NFTArt({
  image,
  name,
  small = false,
}: {
  image?: string;
  name?: string;
  small?: boolean;
}) {
  return (
    <div className={`nft-art ${small ? "small" : ""}`}>
      {image ? (
        <img
          src={image}
          alt={name ?? "NFT"}
          loading="lazy"
          referrerPolicy="no-referrer"
          onError={(e) => {
            const img = e.currentTarget;
            img.hidden = true;
            img.parentElement?.classList.add("image-failed");
          }}
        />
      ) : null}
      <span className={image ? "image-fallback" : "placeholder"}>
        <Icon name="leaf" size={small ? 26 : 44} />
      </span>
    </div>
  );
}
