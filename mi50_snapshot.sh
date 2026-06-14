#!/bin/bash
set -e

# =============================================================================
# MI50 / Radeon VII / gfx906 Infrastructure Snapshot Toolkit v5.5
# ----------------------------------------------------------------------------
# v5.5: ищет ВСЕ папки с llama, проверяет HIP-поддержку,
#       сохраняет LD_LIBRARY_PATH, настраивает ld.so.conf.d
# =============================================================================

# ЭТАП 0: Проверка свободного места
TS_MOUNT=$(findmnt -n -o TARGET /dev/sda1 2>/dev/null || echo "/mnt/backup")
BACKUP_DIR="$TS_MOUNT/rocm_llama_backups/$(date +%Y%m%d_%H%M)"

echo "💽 Проверяю свободное место на $TS_MOUNT..."
df -h "$TS_MOUNT"

AVAILABLE=$(df --output=avail "$TS_MOUNT" | tail -1 | tr -d ' ')
if [ "$AVAILABLE" -lt 20000000 ]; then
    echo "❌ Недостаточно места (нужно ~20 ГБ, доступно: $((AVAILABLE/1024/1024)) ГБ)"
    exit 1
fi

sudo mkdir -p "$BACKUP_DIR"
sudo chown "$USER:$USER" "$BACKUP_DIR"
cd "$BACKUP_DIR" || exit 1
echo "📍 Бэкап в: $BACKUP_DIR"

# ЭТАП 1: ROCm info
echo "🔍 Сохраняю информацию о ROCm..."
hipcc --version > rocm_version.txt 2>/dev/null || echo "hipcc не найден" > rocm_version.txt
rocminfo | grep -E "gfx|Marketing" > gfx_info.txt 2>/dev/null || true

if [ -L /opt/rocm ]; then
    readlink -f /opt/rocm > rocm_symlink_target.txt
    echo "✅ ROCm symlink target: $(cat rocm_symlink_target.txt)"
fi

if [ -d /opt/rocm/lib/rocblas/library ]; then
    find /opt/rocm/lib/rocblas/library -name "*gfx906*" | sort > gfx906_blob_manifest.txt
    GFX906_COUNT=$(wc -l < gfx906_blob_manifest.txt)
    echo "✅ gfx906 manifest: $GFX906_COUNT blobs"
fi

# ЭТАП 2: ROCm Runtime Archive
if ls -d /opt/rocm* 2>/dev/null | grep -q .; then
    echo "📦 Архивирую ROCm runtime..."
    ROCM_REAL=$(readlink -f /opt/rocm 2>/dev/null || echo "/opt/rocm")
    sudo tar -czPf rocm_runtime_backup.tar.gz \
        /opt/rocm "$ROCM_REAL" \
        --exclude='*.a' --exclude='*/doc/*' --exclude='*/share/*' \
        --exclude='*/llvm/lib/clang/*/lib/linux' --exclude='*/examples/*' --exclude='*/test/*' \
        2>/dev/null || true
    gzip -t rocm_runtime_backup.tar.gz 2>/dev/null && echo "✅ ROCm archive OK"
fi

if [ -d "$HOME/.cache/hip" ]; then
    tar -czf hip_cache.tar.gz -C "$HOME" .cache/hip
    echo "⚡ HIP cache сохранен"
fi

# ЭТАП 3: gfx906 Tensile patches
echo "🔥 Сохраняю gfx906 Tensile-патчи..."
mkdir -p gfx906_patch
sudo cp /opt/rocm/lib/rocblas/library/*gfx906* gfx906_patch/ 2>/dev/null || true

if [ -n "$(ls -A gfx906_patch 2>/dev/null)" ]; then
    tar -czf gfx906_patch.tar.gz gfx906_patch
    gzip -t gfx906_patch.tar.gz && echo "✅ gfx906 patch OK ($(ls gfx906_patch | wc -l) файлов)"
fi
rm -rf gfx906_patch

# ЭТАП 4: llama.cpp — ВСЕ папки с проверкой HIP
echo "🔍 Ищу ВСЕ папки с llama..."
HIP_FOUND=0

find "$HOME" -maxdepth 3 -type d -name "*llama*" 2>/dev/null | while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    [ ! -d "$dir/build/bin" ] && continue
    [ ! -f "$dir/build/bin/llama-cli" ] && continue
    
    dirname=$(basename "$dir")
    parentdir=$(dirname "$dir")
    
    echo ""
    echo "📂 Найдена папка: $dir"
    
    # КРИТИЧНО: проверка HIP
    HAS_HIP=0
    if [ -f "$dir/build/bin/libggml-hip.so" ] || [ -f "$dir/build/bin/libggml-hip.so.0" ]; then
        HAS_HIP=1
        echo "  ✅ HIP библиотека найдена (ROCm-версия)"
    elif ldd "$dir/build/bin/llama-cli" 2>/dev/null | grep -q "libggml-hip"; then
        HAS_HIP=1
        echo "  ✅ HIP поддержка обнаружена через ldd"
    fi
    
    if [ "$HAS_HIP" -eq 1 ]; then
        GFX_COUNT=$(strings "$dir/build/bin/llama-cli" 2>/dev/null | grep -c "gfx906" || echo "0")
        if [ "$GFX_COUNT" -gt 0 ]; then
            echo "  ✅ gfx906 kernels в бинарнике ($GFX_COUNT упоминаний)"
        fi
        SUFFIX="_HIP"
    else
        echo "  ⚠️ ВНИМАНИЕ: скомпилирован БЕЗ ROCm/HIP (только CPU!)"
        SUFFIX="_CPU_ONLY"
    fi
    
    # Git state
    if [ -d "$dir/.git" ]; then
        git -C "$dir" rev-parse HEAD > "${dirname}${SUFFIX}_commit.txt" 2>/dev/null || true
        git -C "$dir" diff > "${dirname}${SUFFIX}_local_changes.patch" 2>/dev/null || true
        git -C "$dir" status --short > "${dirname}${SUFFIX}_git_status.txt" 2>/dev/null || true
        git -C "$dir" remote -v > "${dirname}${SUFFIX}_git_remotes.txt" 2>/dev/null || true
    fi
    
    # Source backup
    tar --exclude='build' --exclude='.git' --exclude='*.o' --exclude='*.obj' \
        --exclude='*.so' --exclude='*.a' --exclude='CMakeCache.txt' --exclude='CMakeFiles' \
        -czf "${dirname}${SUFFIX}_source_backup.tar.gz" -C "$parentdir" "$dirname"
    gzip -t "${dirname}${SUFFIX}_source_backup.tar.gz" && echo "  ✅ Source OK"
    
    # Binaries backup
    tar -czf "${dirname}${SUFFIX}_build_bin.tar.gz" -C "$dir/build" bin
    gzip -t "${dirname}${SUFFIX}_build_bin.tar.gz" && echo "  💎 Binaries OK"
    
    # Binary inspection
    "$dir/build/bin/llama-cli" --version > "${dirname}${SUFFIX}_version.txt" 2>/dev/null || true
    strings "$dir/build/bin/llama-cli" | grep -E "gfx[0-9]+" | sort -u > "${dirname}${SUFFIX}_binary_gfx_strings.txt" 2>/dev/null || true
    ldd "$dir/build/bin/llama-cli" > "${dirname}${SUFFIX}_ldd.txt" 2>/dev/null || true
    sha256sum "$dir/build/bin/llama-cli" > "${dirname}${SUFFIX}_llama_cli.sha256" 2>/dev/null || true
    
    # Сохраняем путь к первой HIP-версии
    if [ "$HAS_HIP" -eq 1 ] && [ ! -f working_hip_llama_path.txt ]; then
        echo "$dir" > working_hip_llama_path.txt
    fi
done

if [ -f working_hip_llama_path.txt ]; then
    echo ""
    echo "✅ Найдена рабочая HIP-версия: $(cat working_hip_llama_path.txt)"
else
    echo ""
    echo "❌ ВНИМАНИЕ: не найдено ни одной версии llama.cpp с HIP-поддержкой!"
fi

# ЭТАП 5: Launch Scripts
echo "🚀 Сохраняю launch scripts..."
mkdir -p launch_scripts_backup
find "$HOME" -maxdepth 3 -type f \( -name "*.sh" -o -name "*launch*" -o -name "*server*" \) \
    -exec cp {} launch_scripts_backup/ \; 2>/dev/null || true
[ -n "$(ls -A launch_scripts_backup 2>/dev/null)" ] && tar -czf launch_scripts.tar.gz launch_scripts_backup/
rm -rf launch_scripts_backup

cat > working_launch_example.txt << 'EXAMPLE'
# Рабочий пример запуска сервера
cd ~/llama.cpp/build/bin
ROCR_VISIBLE_DEVICES=1 ./llama-server \
    -m /opt/models/gguf/Qwen3-8B-Q6_K.gguf \
    --host 0.0.0.0 --port 8084 \
    -ngl 99 -c 10240 -b 512 -ub 32 --no-warmup
EXAMPLE

# ЭТАП 6: APT configs & Environment
echo "💾 Сохраняю конфигурацию системы..."
grep -E "(ROCM_PATH|HIP_DEVICE_LIB_PATH|GPU_TARGETS|HSA_OVERRIDE|LD_LIBRARY_PATH|PATH.*rocm)" "$HOME/.bashrc" > env_vars.txt 2>/dev/null || true
cp "$HOME/.bashrc" bashrc_backup.txt 2>/dev/null || true

mkdir -p apt_configs
sudo cp /etc/apt/sources.list.d/{rocm*,amdgpu*,docker*}.list apt_configs/ 2>/dev/null || true
sudo cp /etc/apt/keyrings/{rocm*,amdgpu*}.gpg apt_configs/ 2>/dev/null || true
tar -czf apt_configs.tar.gz apt_configs/ && rm -rf apt_configs/

# ld.so.conf.d backup
if ls /etc/ld.so.conf.d/*rocm* /etc/ld.so.conf.d/*llama* 2>/dev/null | grep -q .; then
    sudo tar -czf ldconf_backup.tar.gz -C /etc/ld.so.conf.d $(ls /etc/ld.so.conf.d/ | grep -E "rocm|llama") 2>/dev/null || true
    echo "✅ ld.so.conf.d backup создан"
fi

echo "build-essential cmake git libcurl4-openssl-dev pkg-config ninja-build wget curl dkms" > required_dev_deps.txt
dpkg -l | grep -E 'rocm|hip|rocblas|miopen|hsa|hsakmt' > rocm_package_versions.txt

# ЭТАП 7: Checksums
echo "🔐 Генерирую SHA256 checksums..."
if ls ./*.tar.gz >/dev/null 2>&1; then
    sha256sum ./*.tar.gz > SHA256SUMS.txt
    echo "✅ SHA256SUMS.txt создан ($(wc -l < SHA256SUMS.txt) архивов)"
fi

# ЭТАП 8: Restore Script
cat > restore.sh << 'REOF'
#!/bin/bash
set -e
cd "$(dirname "$0")" || exit 1
echo "📁 Работаю из: $(pwd)"
echo "🔄 Восстанавливаю ROCm + llama.cpp для gfx906..."

REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
[ -z "$REAL_HOME" ] && REAL_HOME="$HOME"
echo "👤 Целевой пользователь: ${SUDO_USER:-$USER} ($REAL_HOME)"

[ -f SHA256SUMS.txt ] && sha256sum -c SHA256SUMS.txt --quiet || true

# 1. Базовые зависимости
sudo apt update || true
[ -f required_dev_deps.txt ] && xargs -a required_dev_deps.txt sudo apt install -y --no-install-recommends || true

# 2. APT configs
if [ -f apt_configs.tar.gz ]; then
    tar -xzf apt_configs.tar.gz
    sudo cp -f apt_configs/*.list /etc/apt/sources.list.d/ 2>/dev/null || true
    sudo cp -f apt_configs/*.gpg /etc/apt/keyrings/ 2>/dev/null || true
    sudo apt update || echo "⚠️ apt update failed, continuing"
    rm -rf apt_configs/
fi

# 3. ROCm Runtime
if [ -f rocm_runtime_backup.tar.gz ]; then
    echo "📦 Восстанавливаю ROCm runtime..."
    sudo tar -xzPf rocm_runtime_backup.tar.gz
    sudo chmod -R a+x /opt/rocm*/bin 2>/dev/null || true
fi

if [ -f rocm_symlink_target.txt ]; then
    TARGET=$(cat rocm_symlink_target.txt)
    [ -d "$TARGET" ] && sudo ln -sfn "$TARGET" /opt/rocm
fi

# 4. gfx906 Tensile patches
if [ -f gfx906_patch.tar.gz ]; then
    echo "🔥 Восстанавливаю gfx906 Tensile-патчи..."
    tar -xzf gfx906_patch.tar.gz
    sudo cp gfx906_patch/* /opt/rocm/lib/rocblas/library/ 2>/dev/null || true
    rm -rf gfx906_patch
fi

if [ -f gfx906_blob_manifest.txt ]; then
    MISSING=0
    while read -r blob; do
        [ ! -f "$blob" ] && echo "❌ Missing: $blob" && MISSING=$((MISSING+1))
    done < gfx906_blob_manifest.txt
    [ "$MISSING" -eq 0 ] && echo "✅ Все gfx906 blobs на месте"
fi

# 5. HIP Cache
[ -f hip_cache.tar.gz ] && tar -xzf hip_cache.tar.gz -C "$REAL_HOME"

# 6. llama.cpp исходники
for archive in *llama*_source_backup.tar.gz; do
    [ -f "$archive" ] && tar -xzf "$archive" -C "$REAL_HOME"
done

# 7. llama.cpp бинарники с проверкой HIP
HIP_RESTORED=0
for bin_archive in *llama*_build_bin.tar.gz; do
    if [ -f "$bin_archive" ]; then
        dirname=$(echo "$bin_archive" | sed -E 's/_(HIP|CPU_ONLY)_build_bin\.tar\.gz$//')
        llama_dir=$(find "$REAL_HOME" -maxdepth 3 -type d -name "$dirname" 2>/dev/null | head -n1)
        if [ -z "$llama_dir" ]; then
            llama_dir="$REAL_HOME/$dirname"
            mkdir -p "$llama_dir"
        fi
        if [[ "$bin_archive" == *"_HIP_"* ]] || [ "$HIP_RESTORED" -eq 0 ]; then
            echo "📦 Распаковываю: $bin_archive → $llama_dir"
            mkdir -p "$llama_dir/build"
            tar -xzf "$bin_archive" -C "$llama_dir/build"
            chmod -R +x "$llama_dir/build/bin" 2>/dev/null || true
            if [[ "$bin_archive" == *"_HIP_"* ]]; then
                [ -f "$llama_dir/build/bin/llama-cli" ] || {
                    echo "❌ HIP archive restored but llama-cli missing"
                    exit 1
                }
                ls "$llama_dir/build/bin"/libggml-hip.so* >/dev/null 2>&1 || {
                    echo "❌ HIP archive restored but libggml-hip.so missing"
                    exit 1
                }
                echo "✅ HIP binaries verified"
                HIP_RESTORED=1
            fi
        else
            echo "⏭️  Пропускаю CPU_ONLY: $bin_archive (HIP уже восстановлен)"
        fi
    fi
done

# 8. Делаем HIP-версию основной
if [ -f working_hip_llama_path.txt ]; then
    HIP_PATH=$(cat working_hip_llama_path.txt)
    HIP_DIRNAME=$(basename "$HIP_PATH")
    if [ "$HIP_DIRNAME" != "llama.cpp" ] && [ -d "$REAL_HOME/$HIP_DIRNAME" ]; then
        [ -d "$REAL_HOME/llama.cpp" ] && mv "$REAL_HOME/llama.cpp" "$REAL_HOME/llama.cpp.non_hip_backup"
        mv "$REAL_HOME/$HIP_DIRNAME" "$REAL_HOME/llama.cpp"
        echo "✅ Переименовал $HIP_DIRNAME → llama.cpp (HIP-версия)"
    fi
    mkdir -p "$REAL_HOME/bin"
    ln -sf "$REAL_HOME/llama.cpp/build/bin/llama-cli" "$REAL_HOME/bin/" 2>/dev/null || true
    ln -sf "$REAL_HOME/llama.cpp/build/bin/llama-server" "$REAL_HOME/bin/" 2>/dev/null || true
    ln -sf "$REAL_HOME/llama.cpp/build/bin/llama-bench" "$REAL_HOME/bin/" 2>/dev/null || true
    echo "✅ $REAL_HOME/bin симлинки созданы"
fi

# 9. Launch scripts
[ -f launch_scripts.tar.gz ] && tar -xzf launch_scripts.tar.gz

# 10. ld.so.conf.d
if [ -f ldconf_backup.tar.gz ]; then
    sudo tar -xzf ldconf_backup.tar.gz -C /etc/ld.so.conf.d/ 2>/dev/null || true
fi
echo "/opt/rocm/lib" | sudo tee /etc/ld.so.conf.d/rocm-llama.conf > /dev/null
if [ -d "$REAL_HOME/llama.cpp/build/bin" ]; then
    echo "$REAL_HOME/llama.cpp/build/bin" | sudo tee -a /etc/ld.so.conf.d/rocm-llama.conf > /dev/null
    echo "✅ ld.so.conf: $REAL_HOME/llama.cpp/build/bin"
fi
sudo ldconfig

# 11. .bashrc
if [ -f bashrc_backup.txt ]; then
    if [ ! -f "$REAL_HOME/.bashrc" ] || [ -z "$(cat "$REAL_HOME/.bashrc" 2>/dev/null)" ]; then
        cp bashrc_backup.txt "$REAL_HOME/.bashrc"
        chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$REAL_HOME/.bashrc"
        echo "✅ .bashrc восстановлен в $REAL_HOME"
    else
        echo "⚠️ .bashrc уже существует в $REAL_HOME"
    fi
fi

# 12. Финальные переменные окружения
export LD_LIBRARY_PATH=/opt/rocm/lib:"$REAL_HOME/llama.cpp/build/bin":${LD_LIBRARY_PATH:-}
export PATH="$REAL_HOME/bin:/opt/rocm/bin:$PATH"
hash -r

# ВАЛИДАЦИЯ
echo ""
echo "🧪 Проверяю ROCm..."
hipcc --version 2>/dev/null | head -1 || echo "⚠️ hipcc не найден"
rocminfo | grep -c gfx906 | xargs -I{} echo "✅ gfx906 устройств: {}"

echo ""
echo "🧪 Проверяю llama..."
if [ -f "$REAL_HOME/llama.cpp/build/bin/llama-cli" ]; then
    "$REAL_HOME/llama.cpp/build/bin/llama-cli" --list-devices || echo "⚠️ llama-cli не нашёл устройства"
    echo ""
    echo "🔬 GFX targets in binary:"
    strings "$REAL_HOME/llama.cpp/build/bin/llama-cli" | grep -E "gfx[0-9]+" | sort -u | head -5
fi

echo ""
echo "✅ Готово! Среда восстановлена для ${SUDO_USER:-$USER}"
echo "💡 Выполните 'exec bash' или перелогиньтесь для применения PATH"
REOF
chmod +x restore.sh

echo ""
echo "🎉 MI50 INFRASTRUCTURE SNAPSHOT v5.5 ЗАВЕРШЕН!"
echo "📊 Итоговый размер: $(du -sh "$BACKUP_DIR" | cut -f1)"
