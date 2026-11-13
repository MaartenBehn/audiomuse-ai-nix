{
  config,
  pkgs,
  lib,
  ...
}:
with lib;
let
  cfg = config.services.audiomuse-ai;

  pluginsRoot = pkgs.runCommand "audiomuse-plugins-served" {
    nativeBuildInputs = [ pkgs.zip pkgs.jq pkgs.coreutils ];
  } ''
    mkdir -p $out

    PLUGINS_JSON="[]"

    for plugin_dir in ${../plugins}/*/; do
      plugin_dir="''${plugin_dir%/}"
      echo "$plugin_dir"
      # Read metadata from plugin.json
      PLUGIN_ID=$(jq -r '.id // "'"$plugin_dir"'"' "$plugin_dir/plugin.json")
      PLUGIN_NAME=$(jq -r '.name // "'"$plugin_dir"'"' "$plugin_dir/plugin.json")
      PLUGIN_AUTHOR=$(jq -r '.author // "Unknown"' "$plugin_dir/plugin.json")
      PLUGIN_DESC=$(jq -r '.description // ""' "$plugin_dir/plugin.json")

      # Zip the plugin contents directly into the output directory
      ZIP_NAME="''${PLUGIN_ID}_1.0.0.zip"
      echo "$ZIP_NAME"
      (
        cd "$plugin_dir"
        zip -r "$out/$ZIP_NAME" . > /dev/null
      )
      echo "zip done"

      # Compute SHA-256 checksum for the zip file
      SOURCE_URL="http://127.0.0.1:${toString cfg.plugins.port}/''${ZIP_NAME}"
      echo "$SOURCE_URL"

      # Construct the plugin JSON entry
      PLUGIN_JSON=$(jq -n \
        --arg id "$PLUGIN_ID" \
        --arg name "$PLUGIN_NAME" \
        --arg author "$PLUGIN_AUTHOR" \
        --arg desc "$PLUGIN_DESC" \
        --arg source_url "$SOURCE_URL" \
        '{
          id: $id,
          name: $name,
          author: $author,
          description: $desc,
        versions: [
          {
            version: "1.0.0",
            min_core_version: "3.0.0",
            changelog: "",
            imageUrl: "",
            sourceUrl: $source_url,
          }
          ]
        }')

      echo "$PLUGIN_JSON"

      # Append to the plugins array
      PLUGINS_JSON=$(echo "$PLUGINS_JSON" | jq --argjson p "$PLUGIN_JSON" '. + [$p]')
    done

    # Write the complete repository manifest.json
    jq -n --argjson plugins "$PLUGINS_JSON" '{plugins: $plugins}' > $out/manifest.json
  '';
  
  # A helper to generate the numbered default workers list
  defaultWorkerServices = listToAttrs (
    genList (i:
      let
        workerNum = toString (i + 1);
        serviceName = "audiomuse-ai-worker-${workerNum}";
      in {
        name = serviceName;
        value = {
          description = "AudioMuse-AI RQ Worker ${workerNum}";
          after = [
            "audiomuse-ai.service"
          ];
          wantedBy = [ "multi-user.target" ];

          path = with pkgs; [ ffmpeg chromaprint ] ++ (if cfg.plugins.enable then [ cfg.plugins.beets_package ] else []);
          environment = commonEnv;

          serviceConfig = commonServiceConfig // {
            ExecStart = "${cfg.package}/bin/audiomuse-ai-worker";
          };
        };
      }
    ) cfg.workers.count
  );

  # Common environment and service config definitions need to be accessible 
  # inside the let binding or defined before use. Here is the refactored layout:
  commonEnv = {
    # Database - use unix socket for NixOS peer auth
    POSTGRES_USER = cfg.database.user;
    POSTGRES_PASSWORD = ""; 
    POSTGRES_HOST = cfg.database.host;
    POSTGRES_PORT = toString cfg.database.port;
    POSTGRES_DB = cfg.database.name;
    
    # Paths
    DATA_DIR = cfg.dataDir;
    TEMP_DIR = "${cfg.dataDir}/temp_audio";
    PLUGINS_DIR = "${cfg.dataDir}/plugins";

    MODELS_PATH = "${cfg.dataDir}/models";
    LYRICS_MODEL_DIR = "${cfg.dataDir}/models";
    LYRICS_GTE_TOKENIZER_DIR = "${cfg.dataDir}/models/gte-multilingual-base"; 
    EMBEDDING_MODEL_PATH = "${cfg.dataDir}/models/musicnn_embedding.onnx";
    PREDICTION_MODEL_PATH = "${cfg.dataDir}/models/musicnn_prediction.onnx";
    CLAP_AUDIO_MODEL_PATH = "${cfg.dataDir}/models/model_epoch_36.onnx";
    CLAP_TEXT_MODEL_PATH = "${cfg.dataDir}/models/clap_text_model.onnx";
    CLAP_SAE_MODEL_PATH = "${cfg.dataDir}/models/dclap_sae_k20_d1024_best_decoder.onnx";
    CLAP_SAE_ENCODER_PATH = "${cfg.dataDir}/models/dclap_sae_k20_d1024_best_encoder.onnx";
    NEURAL_FINGERPRINT_MODEL_PATH = "${cfg.dataDir}/models/neural_fingerprint.onnx"; 
    NEURAL_FINGERPRINT_CODEBOOK_PATH = "${cfg.dataDir}/models/neural_fingerprint_pq.npz";
    LYRICS_GTE_ONNX_PATH = "${cfg.dataDir}/models/gte-multilingual-base-int8.onnx";
    SILERO_VAD_ONNX_PATH = "${cfg.dataDir}/models/silero_vad.onnx"; 
    
    HF_HOME = "${cfg.dataDir}/.cache/huggingface";
    CLAP_TEXT_EMBEDDINGS_CACHE_PATH = "${cfg.dataDir}/.cache/clap_other_feature_text_embeddings.npz";
    
    HF_HUB_OFFLINE = "1";
    TRANSFORMERS_OFFLINE = "1";
    PYTHONFAULTHANDLER = "1";
    
    # Clean cache dir for every package version update
    NUMBA_CACHE_DIR = "/var/lib/audiomuse-ai/numba-cache/${builtins.baseNameOf (toString cfg.package)}";

  } // lib.optionalAttrs cfg.gpu.enable {
    PER_SONG_MODEL_RELOAD = "false";
    CLAP_MINI_BATCH_SIZE = "8";
  } // cfg.extraEnvironment;

  commonServiceConfig = {
    User = cfg.user;
    Group = cfg.group;
    WorkingDirectory = cfg.dataDir;
    Restart = "always";
    RestartSec = 5;

    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ReadWritePaths = [ 
      cfg.dataDir 
      cfg.musicDir
      "/var/lib/beets"
    ];
    ReadOnlyPaths = [
      cfg.musicDir
      "${cfg.modelsPackage}"
    ] ++ lib.optionals cfg.gpu.enable [
      "/run/opengl-driver"
    ];
  } // lib.optionalAttrs cfg.gpu.enable {
    DeviceAllow = map (dev: "${dev} rw") cfg.gpu.devices;
    SupplementaryGroups = [ "video" "render" ];
  } // lib.optionalAttrs (cfg.environmentFile != null) {
    EnvironmentFile = cfg.environmentFile;
  };
in
{
  options.services.audiomuse-ai = {
    enable = mkEnableOption "AudioMuse-AI music analysis service";

    package = mkOption {
      type = types.package;
      default = pkgs.audiomuse-ai;
      defaultText = literalExpression "pkgs.audiomuse-ai";
      description = "The audiomuse-ai package to use";
    };

    port = mkOption {
      type = types.port;
      default = 8000;
      description = "Port for the Flask API server";
    };

    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Host to bind the Flask API server";
    };

    musicDir = mkOption {
      type = types.path;
      default = "/var/lib/musiclibrary";
      description = "Path to the music library";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/audiomuse-ai";
      description = "Directory for AudioMuse-AI data and configuration";
    };

    user = mkOption {
      type = types.str;
      default = "audiomuse";
      description = "User to run AudioMuse-AI as";
    };

    group = mkOption {
      type = types.str;
      default = "audiomuse";
      description = "Group to run AudioMuse-AI as";
    };

    modelsPackage = mkOption {
      type = types.package;
      default = pkgs.audiomuse-ai-models;
      defaultText = literalExpression "pkgs.audiomuse-ai-models";
      description = "Package containing ONNX models";
    };

    gpu = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable GPU (NVIDIA) support — controls device access, groups, and OpenGL paths";
      };

      devices = mkOption {
        type = types.listOf types.str;
        default = [
          "/dev/nvidia0"
          "/dev/nvidiactl"
          "/dev/nvidia-uvm"
          "/dev/nvidia-uvm-tools"
        ];
        description = "NVIDIA device paths to allow access to";
      };
    };

    workers = {
      count = mkOption {
        type = types.int;
        default = 2;
        description = "Number of RQ worker processes";
      };
    };

    database = {
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "PostgreSQL host";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port";
      };

      name = mkOption {
        type = types.str;
        default = "audiomuse";
        description = "PostgreSQL database name";
      };

      user = mkOption {
        type = types.str;
        default = "audiomuse";
        description = "PostgreSQL user";
      };
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing environment variables (e.g. GEMINI_API_KEY)";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables to set for all AudioMuse-AI services";
    }; 

    plugins = {
      enable = mkEnableOption "Enable serving the plugins folder locally"; 
      port = mkOption {
        type = types.port;
        default = 8001;
        description = "Port for the plugins served locally";
      };
      beets_package = mkOption {
        type = types.package;
        default = pkgs.beets;
        defaultText = literalExpression "pkgs.beets";
        description = "The beets package to use";
      };
    };
  };
  
  config = mkIf cfg.enable {

    # PostgreSQL database
    services.postgresql = {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };
    
    # Create data directory
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/logs 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/plugins 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/.cache 0750 ${cfg.user} ${cfg.group} -"
      "C+ ${cfg.dataDir}/.cache/huggingface 0750 ${cfg.user} ${cfg.group} - ${cfg.modelsPackage}/cache/huggingface"
      "C+ ${cfg.dataDir}/models 0750 ${cfg.user} ${cfg.group} - ${cfg.modelsPackage}/models"
    ];

    # User and group
    users.users.${cfg.user} = mkIf (cfg.user == "audiomuse") {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = lib.optionals cfg.gpu.enable [ "video" "render" ];
    };
    users.groups.${cfg.group} = mkIf (cfg.group == "audiomuse") { };

    # Systemd services
    systemd.services = (rec {
      # Main Flask API server
      audiomuse-ai = {
        description = "AudioMuse-AI Music Analysis API";
        after = [
          "network.target"
          "postgresql.service"
        ];
        wants = [
          "postgresql.service"
        ];
        wantedBy = [ "multi-user.target" ];

        path = with pkgs; [ ffmpeg chromaprint ] ++ (if cfg.plugins.enable then [ cfg.plugins.beets_package ] else []);
        environment = commonEnv;

        serviceConfig = commonServiceConfig // {
          ExecStart = "${cfg.package}/bin/audiomuse-ai";
        };
      };

      # RQ Worker (high priority)
      audiomuse-ai-worker-high = {
        description = "AudioMuse-AI RQ Worker (High Priority)";
        after = [
          "audiomuse-ai.service"
        ];
        wantedBy = [ "multi-user.target" ];

        path = with pkgs; [ ffmpeg chromaprint ];
        environment = commonEnv;

        serviceConfig = commonServiceConfig // {
          ExecStart = "${cfg.package}/bin/audiomuse-ai-worker-high";
        };
      };
    }) // defaultWorkerServices;

    # Firewall
    networking.firewall.allowedTCPPorts = (lib.optionals (cfg.host == "0.0.0.0") [ cfg.port ]);

    services.nginx = mkIf cfg.plugins.enable {
      enable = true;
      virtualHosts."audiomuse-plugins" = {
        listen = [
          {
            addr = "127.0.0.1";
            port = cfg.plugins.port;
          }
        ];
        root = pluginsRoot;

        locations."/" = {
          extraConfig = ''
            # Allow AudioMuse-AI to fetch the manifest across ports/origins
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "GET, OPTIONS";

            # Enable directory listing for debugging if needed
            autoindex on;
          '';
        };
      };
    };
  }; 
}
