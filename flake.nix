{
  description = "Deno - A secure runtime for JavaScript and TypeScript";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/25.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        rust-toolchain-config = builtins.fromTOML (builtins.readFile ./rust-toolchain.toml);
        rust-channel = rust-toolchain-config.toolchain.channel;
        rust-components = rust-toolchain-config.toolchain.components or [ ];
        rust-toolchain = pkgs.rust-bin.stable."${rust-channel}".default.override {
          extensions = rust-components ++ [ "rust-src" ];
        };
        # Build dependencies
        buildDeps = with pkgs; [
          coreutils
          # Core build tools
          rust-toolchain
          # cargo
          # rustc

          # Native compilation tools
          cmake
          gcc
          clang
          llvm
          lld

          # Protocol Buffers compiler
          protobuf

          # Python 3 for WPT tests
          python3

          # Additional system libraries
          pkg-config
          openssl
          zlib
          libffi
        ] ++ (pkgs.lib.optionals pkgs.stdenv.isDarwin [
          # macOS specific
          darwin.apple_sdk.frameworks.CoreFoundation
          darwin.apple_sdk.frameworks.Security
          darwin.apple_sdk.frameworks.SystemConfiguration
        ]) ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [
          # Linux specific
          glib
          libclang
        ]) ++ (pkgs.lib.optionals (pkgs.stdenv.hostPlatform.isWindows) [
          # Windows specific
          windows.pthreads
        ]);

        # Development tools
        devTools = with pkgs; [
          # Code formatting and linting
          dprint
          rustfmt
          clippy

          # Git
          git

          # General utilities
          curl
          wget
          jq
          nodejs
        ];

        # Complete environment
        allDeps = buildDeps ++ devTools;
        vscodeSettings = pkgs.writeTextFile
          {
            name = "vscode-settings.json";
            text = builtins.toJSON {
              "rust-analyzer.cargo.extraEnv" = {
                "PATH" = pkgs.lib.makeBinPath allDeps;
                "CC" = "${pkgs.gcc}/bin/gcc";
                "RUSTC_LINKER" = "${pkgs.gcc}/bin/gcc";
              };
              "nix.enableLanguageServer" = true;
              "nix.serverPath" = pkgs.nil + "/bin/nil";
              "nix.serverSettings" = {
                "nil" = {
                  "formatting" = {
                    "command" = [ (pkgs.nixpkgs-fmt + "/bin/nixpkgs-fmt") ];
                  };
                };
              };
            };
          };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = allDeps;

          shellHook = ''
            mkdir -p ./.vscode
            cat ${vscodeSettings} > ./.vscode/settings.json
          '';

          # Set environment variables for the build
          CARGO_TARGET_DIR = "target";
          RUST_BACKTRACE = "1";

          # Ensure proper linking
          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.zlib.dev}/lib/pkgconfig";

          # For macOS
          NIX_LDFLAGS = "-L${pkgs.lib.getLib pkgs.openssl}/lib -L${pkgs.lib.getLib pkgs.zlib}/lib";

          # For Linux
          NIX_CFLAGS_COMPILE = "-I${pkgs.openssl.dev}/include -I${pkgs.zlib.dev}/include";
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
        };

        # Package definition for building Deno (local source)
        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "deno";
          version = "2.5.0";
          __noChroot = true;

          src = pkgs.fetchFromGitHub {
            owner = "nktpro";
            repo = "deno";
            rev = "feature/fix-otel";
            sha256 = "sha256-pjFHZK6NHYR93VsrDU5V7XO4wn+la4tBuyA/AA0bLd0=";
          };

          cargoLock = {
            lockFile = ./Cargo.lock;
            outputHashes = {
              # Git dependencies from https://github.com/nktpro/opentelemetry-rust?branch=feature%2Ffix-observable
              # All packages share the same git commit hash: 6357ef371697dc3eca8e36e8fc1478a3c8d6001b
              # "opentelemetry-0.27.0" = "sha256-2oDXw2ahOv3SwLxBmpJWq0m1YxsnAp7dF3CpvsmNjKc=";
              # "opentelemetry-http-0.27.0" = "sha256-2oDXw2ahOv3SwLxBmpJWq0m1YxsnAp7dF3CpvsmNjKc=";
              # "opentelemetry-otlp-0.27.0" = "sha256-2oDXw2ahOv3SwLxBmpJWq0m1YxsnAp7dF3CpvsmNjKc=";
              # "opentelemetry-semantic-conventions-0.27.0" = "sha256-2oDXw2ahOv3SwLxBmpJWq0m1YxsnAp7dF3CpvsmNjKc=";
              # "opentelemetry_sdk-0.27.0" = "sha256-2oDXw2ahOv3SwLxBmpJWq0m1YxsnAp7dF3CpvsmNjKc=";
              "opentelemetry-0.27.0" = "sha256-579+gB25eCZxAtf0TGdSQ9Hvetp9phgDZrGLjJD2XSA=";
              "opentelemetry-http-0.27.0" = "sha256-579+gB25eCZxAtf0TGdSQ9Hvetp9phgDZrGLjJD2XSA=";
              "opentelemetry-otlp-0.27.0" = "sha256-579+gB25eCZxAtf0TGdSQ9Hvetp9phgDZrGLjJD2XSA=";
              "opentelemetry-semantic-conventions-0.27.0" = "sha256-579+gB25eCZxAtf0TGdSQ9Hvetp9phgDZrGLjJD2XSA=";
              "opentelemetry_sdk-0.27.0" = "sha256-579+gB25eCZxAtf0TGdSQ9Hvetp9phgDZrGLjJD2XSA=";
            };
          };

          nativeBuildInputs = buildDeps ++ [ pkgs.cacert ];

          buildInputs = with pkgs; [
            openssl
            zlib
            libffi
          ] ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [
            glib
            libclang
          ]);

          # Build configuration
          cargoBuildFlags = [ "--bin" "deno" "--bin" "denort" ];

          # Skip tests that require network access or special setup
          doCheck = false;

          # Environment variables for the build
          CARGO_TARGET_DIR = "target";
          RUST_BACKTRACE = "1";

          # Ensure proper linking
          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig:${pkgs.zlib.dev}/lib/pkgconfig";

          # For macOS
          NIX_LDFLAGS = "-L${pkgs.lib.getLib pkgs.openssl}/lib -L${pkgs.lib.getLib pkgs.zlib}/lib";

          # For Linux
          NIX_CFLAGS_COMPILE = "-I${pkgs.openssl.dev}/include -I${pkgs.zlib.dev}/include";
          LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
        };
      });
}
