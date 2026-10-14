{ gpuSupport ? true }:
final: prev:
let
  # Voyager - Spotify's ANN library (not in nixpkgs)
  voyager = final.python312Packages.buildPythonPackage rec {
    pname = "voyager";
    version = "2.1.0";
    format = "wheel";

    src = final.fetchPypi {
      inherit pname version format;
      dist = "cp312";
      python = "cp312";
      abi = "cp312";
      platform = "manylinux_2_17_x86_64.manylinux2014_x86_64";
      hash = "sha256-lBW5ySO6xJPVxo1VrlXEKJFTwj+fR4Qik03mGsuvTAE=";
    };

    # Prebuilt manylinux wheel: patchelf it against the Nix C++ runtime.
    # Without this the extension module cannot resolve libstdc++.so.6, so
    # `import voyager` fails both in the import check and at runtime.
    nativeBuildInputs = [ final.autoPatchelfHook ];
    buildInputs = [ final.stdenv.cc.cc.lib ];

    # Binary wheel, nothing to compile
    propagatedBuildInputs = with final.python312Packages; [ numpy ];

    pythonImportsCheck = [ "voyager" ];

    meta = with final.lib; {
      description = "Spotify's library for approximate nearest-neighbor search";
      homepage = "https://github.com/spotify/voyager";
      license = licenses.asl20;
    };
  };

  # AudioMuse-AI Python environment with all dependencies
  audiomuse-ai-python = final.python312.withPackages (ps: with ps; [
    # Web framework
    flask
    flask-cors
    flasgger
    gunicorn

    # Task queue
    redis
    rq

    # Database
    psycopg2
    sqlglot

    # Audio processing
    librosa
    soundfile
    resampy
    pydub
    mutagen
    av

    # ML/Scientific
    numpy
    scipy
    numba
    scikit-learn
    umap-learn
    transformers
    sentencepiece
    tqdm

    # ONNX
    onnx
    onnxruntime  # CUDA enabled via global cudaSupport = true

    # Utilities
    pyyaml
    requests
    rapidfuzz
    ftfy
    packaging
    protobuf
    httpx
    psutil
    zstandard

    # Auth & Security
    argon2-cffi
    pyjwt

    # Integrations & Language
    langdetect
    python-mpd2
    wn

    # LLM integrations
    google-genai
    mistralai

    # MCP (Model Context Protocol)
    mcp

    # Voyager (from our custom package)
    voyager
  ] ++ final.lib.optionals gpuSupport [
    # GPU-accelerated ML (RAPIDS cuML)
    cupy
    final.python312Packages.rmm
    final.python312Packages.pylibraft
    final.python312Packages.cuvs
    final.python312Packages.cuml
  ]);
in
{
  # AudioMuse-AI - Music analysis and playlist generation service
  audiomuse-ai = final.stdenvNoCC.mkDerivation rec {
    pname = "audiomuse-ai";
    version = "3.6.3";

    src = final.fetchFromGitHub {
      owner = "NeptuneHub";
      repo = "AudioMuse-AI";
      rev = "v${version}";
      hash = "sha256-UX1hSChAAwtRJnbouDHjlNcGP3vyUiaC9q1wEKuB6HA=";
    };

    nativeBuildInputs = [ final.makeWrapper ];

    buildInputs = [
      audiomuse-ai-python
      final.ffmpeg
    ];

    postPatch = ''
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/audiomuse-ai
      cp -r . $out/lib/audiomuse-ai/

      mkdir -p $out/bin

      # Main Flask app
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai \
        --add-flags "$out/lib/audiomuse-ai/app.py" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg final.chromaprint ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      # Worker
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai-worker \
        --add-flags "-m" \
        --add-flags "taskqueue.worker" \
        --add-flags "--queue default" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg final.chromaprint ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      # High-priority Worker
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai-worker-high \
        --add-flags "-m" \
        --add-flags "taskqueue.worker" \
        --add-flags "--queue high" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg final.chromaprint ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "AI-powered music analysis and playlist generation";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

  audiomuse-ai-models = final.stdenvNoCC.mkDerivation {
    pname = "audiomuse-ai-models";
    version = "5.0.0";

    dontUnpack = true;

    # MusicNN (renamed in v4.0.0-model)
    musicnn_embedding = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/musicnn_embedding.onnx";
      hash = "sha256-pIrYh5UKVXrvu03N31itSAIhP/X8b7Ue2jUHzXl7ubA=";
    };
    musicnn_prediction = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/musicnn_prediction.onnx";
      hash = "sha256-DU543UPGEK7IjAmeQfSolpeX2lrCYS6myiH6qeGkKPM=";
    };

    fingerprint = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/neural_fingerprint.onnx";
      hash = "sha256-tlgU2qfafXw96JQlCTbbbkNj94vUHjEPRZfdybRvKVs=";
    };
    fingerprint_pq = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/neural_fingerprint_pq.npz";
      hash = "sha256-iLGmb945pBaHTFGB6OSEI19iGl3GNw8FWVkQ4KMz7Do=";
    };

    huggingface_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/huggingface_models.tar.gz";
      hash = "sha256-AqeNbkI0BMcnEWj3QPF+Q9vBCUf3Rt/EIFZwinRsyz0=";
    };

    clap_audio = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx";
      hash = "sha256-F4YEA/j8kK/4rAYyoHQeteWNjAsK0vzlztlnJ0sOqXE=";
    };
    clap_audio_data = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx.data";
      hash = "sha256-KnNbI8Kq17Etn/yFM0zrzGWcB2ltL/YOLjeNoott9lc=";
    };

    clap_text = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/clap_text_model.onnx";
      hash = "sha256-IA1I85Bf8fJyr1AG3ZhR+UBxp93k6v2cB7wJxaxlpxQ=";
    };

    sea_encode = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI-SAE/releases/download/v1/dclap_sae_k20_d1024_best_encoder.onnx";
      hash = "sha256-2BcjzH0UVmBX6LGZ8rxOo+oeLKenlSmkDz/NU5n5dvY=";
    };

    sea_decode = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI-SAE/releases/download/v1/dclap_sae_k20_d1024_best_decoder.onnx";
      hash = "sha256-exbuBseYEGZK6gJuK20ptl22jXVth77oioVaHiz/y/Y=";
    };

    whisper_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/lyrics_model_whisper.tar.gz";
      hash = "sha256-+p9IJeGpGDlMGmOwy3ykOrHfi+kDVa0D56+V7j0/FRE=";
    };

    silero_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/lyrics_model_silero_vad.tar.gz";
      hash = "sha256-ZeXlw9e/XlvHxHv0K7vmadv6FZVDvUdeDCPO06p6w7Q=";
    };

    gte_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v5.0.0-model/lyrics_model_gte_vnni.tar.gz";
      hash = "sha256-X4pJyHPHYvAajaeQ9B+Z29qsbx8g1MCi26QHzMYMx8w=";
    };
    
    nativeBuildInputs = [ final.gnutar final.gzip ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/models

      cp $musicnn_embedding $out/models/musicnn_embedding.onnx
      cp $musicnn_prediction $out/models/musicnn_prediction.onnx

      cp $fingerprint $out/models/neural_fingerprint.onnx
      cp $fingerprint_pq $out/models/neural_fingerprint_pq.npz

      mkdir -p $out/cache/huggingface
      tar -xzf $huggingface_models -C $out/cache/huggingface

      cp $clap_audio $out/models/model_epoch_36.onnx
      cp $clap_audio_data $out/models/model_epoch_36.onnx.data
      cp $clap_text $out/models/clap_text_model.onnx
      
      cp $sea_encode $out/models/dclap_sae_k20_d1024_best_encoder.onnx
      cp $sea_decode $out/models/dclap_sae_k20_d1024_best_decoder.onnx

      tar -xzf $whisper_models -C $out/models
      tar -xzf $silero_models -C $out/models
      tar -xzf $gte_models -C $out/models

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "ONNX models for AudioMuse-AI";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };

  # Navidrome plugins — extend the upstream navidromePlugins set with our
  # AudioMuse-AI plugin. discord-rich-presence is already in upstream
  # nixos-unstable (navidromePlugins.discord-rich-presence v1.0.0).
  navidromePlugins = prev.navidromePlugins.extend (self: super: {
    audiomuse-ai = final.buildNavidromePlugin {
      pname = "audiomuse-ai";
      version = "unstable-2026-05-13";

      src = final.fetchFromGitHub {
        owner = "NeptuneHub";
        repo = "AudioMuse-AI-NV-plugin";
        rev = "66154bbdd76dd2159b70ec2ac5bc09cc57e20baf";
        hash = "sha256-8MTCyIxLaPkXGsATq44PNx2yJzgaWpp5c4hg0J+j6Yo=";
      };

      vendorHash = "sha256-mXes+doBSa5kcfHp1cuzTz30wnyyPN7NLC0iOSL8FDo=";

      meta = with final.lib; {
        description = "AudioMuse-AI plugin for Navidrome - AI-powered similar tracks";
        homepage = "https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin";
        license = licenses.mit;
      };
    };
  });

  # anyio, rq, and watchfiles test suites fail in the sandbox / with Python 3.12.15
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (python-final: python-prev: final.lib.optionalAttrs (python-prev.isPy312 or false) {
      anyio = python-prev.anyio.overridePythonAttrs (old: {
        doCheck = false;
        doInstallCheck = false;
      });
      rq = python-prev.rq.overridePythonAttrs (old: {
        doCheck = false;
        doInstallCheck = false;
      });
      watchfiles = python-prev.watchfiles.overridePythonAttrs (old: {
        doCheck = false;
        doInstallCheck = false;
      });
    })
  ];

  # Valkey (Redis fork) has flaky cluster/replication tests — skip them
  valkey = prev.valkey.overrideAttrs (old: { doCheck = false; });
}
