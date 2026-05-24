#!/bin/bash
set -e

# =============================================================================
# MI50 / Radeon VII / gfx906 Infrastructure Snapshot Toolkit v5.4
# ----------------------------------------------------------------------------
# Назначение: сохранение работающего ROCm + llama.cpp-gfx906 стека
# Философия: inference-stack-level snapshot (system-level = Timeshift)
# =============================================================================

# ==========================================
# ЭТАП 0: Проверка свободного места
# ==========================================
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

# ==========================================
# ЭТАП 1: ROCm Version & Symlinks (version-agnostic)
# ==========================================
echo "🔍 Сохраняю информацию о ROCm..."
hipcc --version > rocm_version.txt 2>/dev/null || echo "hipcc не найден" > rocm_version.txt
rocminfo | grep -E "gfx|Marketing" > gfx_info.txt 2>/dev/null || echo "rocminfo недоступен" > gfx_info.txt

if ls -d /opt/rocm* 2>/dev/null | grep -q .; then
    find /opt/rocm* -type l -ls > rocm_symlinks.txt 2>/dev/null || true
fi

# Сохраняем target симлинка /opt/rocm (version-agnostic)
if [ -L /opt/rocm ]; then
    readlink -f /opt/rocm > rocm_symlink_target.txt
    echo "✅ ROCm symlink target: $(cat rocm_symlink_target.txt)"
fi

# gfx906 manifest (для future diffing)
if [ -d /opt/rocm/lib/rocblas/library ]; then
    find /opt/rocm/lib/rocblas/library -name "*gfx906*" | sort > gfx906_blob_manifest.txt
    GFX906_COUNT=$(wc -l < gfx906_blob_manifest.txt)
    echo "✅ gfx906 manifest: $GFX906_COUNT blobs"
fi

# ==========================================
# ЭТАП 2: ROCm Runtime Archive (с explicit symlink target)
# ==========================================
if ls -d /opt/rocm* 2>/dev/null | grep -q .; then
    echo "📦 Архивирую ROCm runtime..."
    # Явно архивируем и симлинк, и его target (детерминированный restore)
    ROCM_REAL=$(readlink -f /opt/rocm 2>/dev/null || echo "/opt/rocm")
    sudo tar -czPf rocm_runtime_backup.tar.gz \
        /opt/rocm "$ROCM_REAL" \
        --exclude='*.a' --exclude='*/doc/*' --exclude='*/share/*' \
        --exclude='*/llvm/lib/clang/*/lib/linux' --exclude='*/examples/*' --exclude='*/test/*' \
        2>/dev/null || true
    
    gzip -t rocm_runtime_backup.tar.gz 2>/dev/null && echo "✅ ROCm archive OK (symlink: /opt/rocm → $ROCM_REAL)"
fi

# HIP cache — optional (только если есть)
if [ -d "$HOME/.cache/hip" ]; then
    tar -czf hip_cache.tar.gz -C "$HOME" .cache/hip
    echo "⚡ HIP cache сохранен"
else
    echo "ℹ️ HIP cache отсутствует (пропускаю)"
fi

# ==========================================
# ЭТАП 3: gfx906 Tensile-патчи (отдельно!)
# ==========================================
echo "🔥 Сохраняю gfx906 Tensile-патчи..."
mkdir -p gfx906_patch
sudo cp /opt/rocm/lib/rocblas/library/*gfx906* gfx906_patch/ 2>/dev/null || true

if [ -n "$(ls -A gfx906_patch 2>/dev/null)" ]; then
    tar -czf gfx906_patch.tar.gz gfx906_patch
    gzip -t gfx906_patch.tar.gz && echo "✅ gfx906 patch OK ($(ls gfx906_patch | wc -l) файлов)"
fi
rm -rf gfx906_patch

# ==========================================
# ЭТАП 4: llama.cpp (Source + Binaries + Git + LDD + SHA256)
# ==========================================
echo "🔍 Ищу llama.cpp и форки..."
LLAMA_DIRS=$(find "$HOME" -maxdepth 3 -type d \( -name "llama.cpp" -o -name "llama.cpp-gfx906" \) 2>/dev/null)

if [ -n "$LLAMA_DIRS" ]; then
    # Безопасный цикл (защита от пробелов в путях)
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        dirname=$(basename "$dir")
        parentdir=$(dirname "$dir")
        
        if [ -d "$dir/.git" ]; then
            git -C "$dir" rev-parse HEAD > "${dirname}_commit.txt" 2>/dev/null || true
            git -C "$dir" diff > "${dirname}_local_changes.patch" 2>/dev/null || true
            git -C "$dir" status --short > "${dirname}_git_status.txt" 2>/dev/null || true
            git -C "$dir" remote -v > "${dirname}_git_remotes.txt" 2>/dev/null || true
        fi
        
        # Source backup (без build cache, .git, object files)
        tar --exclude='build' --exclude='.git' --exclude='*.o' --exclude='*.obj' \
            --exclude='*.so' --exclude='*.a' --exclude='CMakeCache.txt' --exclude='CMakeFiles' \
            -czf "${dirname}_source_backup.tar.gz" -C "$parentdir" "$dirname"
        gzip -t "${dirname}_source_backup.tar.gz" && echo "✅ $dirname Source OK"
        
        # Binaries backup
        if [ -d "$dir/build/bin" ]; then
            tar -czf "${dirname}_build_bin.tar.gz" -C "$dir/build" bin
            gzip -t "${dirname}_build_bin.tar.gz" && echo "💎 $dirname Binaries OK"
            
            if [ -f "$dir/build/bin/llama-cli" ]; then
                "$dir/build/bin/llama-cli" --version > "${dirname}_version.txt" 2>/dev/null || true
                strings "$dir/build/bin/llama-cli" | grep -E "gfx[0-9]+" | sort -u > "${dirname}_binary_gfx_strings.txt" 2>/dev/null || true
                ldd "$dir/build/bin/llama-cli" > "${dirname}_ldd.txt" 2>/dev/null || true
                sha256sum "$dir/build/bin/llama-cli" > "${dirname}_llama_cli.sha256" 2>/dev/null || true
                echo "🔬 Binary: $(wc -l < "${dirname}_binary_gfx_strings.txt") gfx targets, $(wc -l < "${dirname}_ldd.txt") libs"
            fi
        fi
    done <<< "$LLAMA_DIRS"
fi

# ==========================================
# ЭТАП 5: Launch Scripts & Working Examples
# ==========================================
echo "🚀 Сохраняю launch scripts..."
mkdir -p launch_scripts_backup
if [ -n "$LLAMA_DIRS" ]; then
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        find "$dir" -maxdepth 2 -type f -name "*.sh" -exec cp {} launch_scripts_backup/ \; 2>/dev/null || true
    done <<< "$LLAMA_DIRS"
fi
find "$HOME" -maxdepth 2 -type f \( -name "*launch*.sh" -o -name "*server*.sh" -o -name "*bench*.sh" \) \
    -exec cp {} launch_scripts_backup/ \; 2>/dev/null || true

[ -n "$(ls -A launch_scripts_backup 2>/dev/null)" ] && tar -czf launch_scripts.tar.gz launch_scripts_backup/
rm -rf launch_scripts_backup

# Рабочий пример запуска (чтобы не вспоминать флаги через полгода)
cat > working_launch_example.txt << 'EOF'
# Рабочий пример запуска сервера (адаптируйте под ваши модели)
# Для Dual Radeon VII используйте ROCR_VISIBLE_DEVICES=0,1
#
# Пример для iacopPBK fork:
ROCR_VISIBLE_DEVICES=0,1 ~/llama.cpp-gfx906/build/bin/llama-server \
    -m /path/to/your/model.gguf \
    -ngl 99 \
    -c 8192 \
    -b 512 \
    --host 0.0.0.0 \
    --port 8080
#
# Для оверклокинга через UPP (MI50):
#   sudo ./SCRIPT_overclock_upp_MI50.sh
EOF

cat > benchmark_notes_TEMPLATE.txt << 'EOF'
# Benchmark Notes (заполните после тестов)
# Model: [имя модели]
# Setup: Dual Radeon VII (gfx906), ROCm 7.x, iacopPBK fork
# Context: [размер]
# Prompt processing: [t/s]
# Generation: [t/s]
# Stability: [100% / issues]
EOF

# ==========================================
# ЭТАП 6: APT configs & Essential Packages
# ==========================================
echo "💾 Сохраняю конфигурацию системы..."
grep -E "(ROCM_PATH|HIP_DEVICE_LIB_PATH|GPU_TARGETS|HSA_OVERRIDE|PATH.*rocm)" "$HOME/.bashrc" > env_vars.txt 2>/dev/null || true
cp "$HOME/.bashrc" bashrc_backup.txt 2>/dev/null || true

mkdir -p apt_configs
sudo cp /etc/apt/sources.list.d/{rocm*,amdgpu*,docker*}.list apt_configs/ 2>/dev/null || true
sudo cp /etc/apt/keyrings/{rocm*,amdgpu*}.gpg apt_configs/ 2>/dev/null || true
tar -czf apt_configs.tar.gz apt_configs/ && rm -rf apt_configs/

echo "build-essential cmake git libcurl4-openssl-dev pkg-config ninja-build wget curl dkms" > required_dev_deps.txt
dpkg -l | grep -E 'rocm|hip|rocblas|miopen|hsa|hsakmt' > rocm_package_versions.txt

# ==========================================
# ЭТАП 7: Checksum Manifest
# ==========================================
echo "🔐 Генерирую SHA256 checksums..."
if ls ./*.tar.gz >/dev/null 2>&1; then
    sha256sum ./*.tar.gz > SHA256SUMS.txt
    echo "✅ SHA256SUMS.txt создан ($(wc -l < SHA256SUMS.txt) архивов)"
else
    echo "⚠️ Нет .tar.gz архивов для checksum"
fi

# ==========================================
# ЭТАП 8: Restore Script
# ==========================================
cat > restore.sh << 'REOF'
#!/bin/bash
set -e
echo "🔄 Восстанавливаю ROCm + llama.cpp для gfx906..."

if [ -f SHA256SUMS.txt ] && command -v sha256sum &> /dev/null; then
    echo "🔐 Проверяю целостность архивов..."
    sha256sum -c SHA256SUMS.txt --quiet || echo "⚠️ Есть расхождения в checksums!"
fi

# 1. Базовые зависимости
sudo apt update
[ -f required_dev_deps.txt ] && xargs -a required_dev_deps.txt sudo apt install -y --no-install-recommends || true

# 2. APT configs
if [ -f apt_configs.tar.gz ]; then
    tar -xzf apt_configs.tar.gz
    sudo cp -f apt_configs/*.list /etc/apt/sources.list.d/ 2>/dev/null || true
    sudo cp -f apt_configs/*.gpg /etc/apt/keyrings/ 2>/dev/null || true
    sudo apt update && rm -rf apt_configs/
fi

# 3. ROCm Runtime
if [ -f rocm_runtime_backup.tar.gz ]; then
    sudo tar -xzPf rocm_runtime_backup.tar.gz
    sudo chmod -R a+x /opt/rocm*/bin 2>/dev/null || true
fi

# Version-agnostic symlink restore
if [ -f rocm_symlink_target.txt ]; then
    TARGET=$(cat rocm_symlink_target.txt)
    if [ -d "$TARGET" ]; then
        sudo ln -sfn "$TARGET" /opt/rocm
        echo "✅ /opt/rocm → $TARGET"
    else
        echo "⚠️ Target $TARGET не найден (возможно, другая версия ROCm)"
    fi
fi

# 4. gfx906 Tensile-патчи
if [ -f gfx906_patch.tar.gz ]; then
    tar -xzf gfx906_patch.tar.gz
    sudo cp gfx906_patch/* /opt/rocm/lib/rocblas/library/ 2>/dev/null || true
    rm -rf gfx906_patch
fi

# gfx906 manifest validation
if [ -f gfx906_blob_manifest.txt ]; then
    MISSING=0
    while read -r blob; do
        [ ! -f "$blob" ] && echo "❌ Missing: $blob" && MISSING=$((MISSING+1))
    done < gfx906_blob_manifest.txt
    [ "$MISSING" -eq 0 ] && echo "✅ Все gfx906 blobs на месте"
fi

# 5. HIP Cache
[ -f hip_cache.tar.gz ] && tar -xzf hip_cache.tar.gz -C "$HOME" && echo "⚡ HIP cache восстановлен"

# 6. llama.cpp (Source + Binaries + ~/bin symlinks)
for archive in llama.cpp*_source_backup.tar.gz; do [ -f "$archive" ] && tar -xzf "$archive" -C "$HOME"; done
for bin_archive in llama.cpp*_build_bin.tar.gz; do
    if [ -f "$bin_archive" ]; then
        dirname=$(echo "$bin_archive" | sed 's/_build_bin.tar.gz//')
        llama_dir=$(find "$HOME" -maxdepth 3 -type d -name "$dirname" 2>/dev/null | head -n1)
        if [ -n "$llama_dir" ]; then
            mkdir -p "$llama_dir/build"
            tar -xzf "$bin_archive" -C "$llama_dir/build"
            chmod -R +x "$llama_dir/build/bin" 2>/dev/null || true
            
            mkdir -p "$HOME/bin"
            ln -sf "$llama_dir/build/bin/llama-cli" "$HOME/bin/" 2>/dev/null || true
            ln -sf "$llama_dir/build/bin/llama-server" "$HOME/bin/" 2>/dev/null || true
            echo "✅ ~/bin symlinks созданы"
        fi
    fi
done

# 7. Launch scripts
[ -f launch_scripts.tar.gz ] && tar -xzf launch_scripts.tar.gz

# 8. .bashrc (с предупреждением)
if [ -f bashrc_backup.txt ]; then
    if [ ! -f "$HOME/.bashrc" ] || [ -z "$(cat "$HOME/.bashrc")" ]; then
        cp bashrc_backup.txt "$HOME/.bashrc"
        echo "✅ .bashrc восстановлен автоматически"
    else
        echo "⚠️ .bashrc уже существует. Для восстановления: cp bashrc_backup.txt ~/.bashrc"
    fi
fi

# 9. PATH fix & Hash reset
export PATH="$HOME/bin:/opt/rocm/bin:$PATH"
echo "$PATH" > restored_path.txt
hash -r

sudo ldconfig

# ==========================================
# 🧪 ВАЛИДАЦИЯ СРЕДЫ
# ==========================================
echo ""
echo "🧪 Проверяю ROCm runtime..."
hipcc --version || echo "⚠️ hipcc не найден"
rocminfo | grep gfx || echo "⚠️ rocminfo не видит GPU"

echo ""
echo "🧪 Проверяю llama runtime..."
LLAMA_CLI=$(find "$HOME" -maxdepth 4 -type f -name "llama-cli" -executable 2>/dev/null | head -n1)
if [ -n "$LLAMA_CLI" ]; then
    "$LLAMA_CLI" --list-devices || echo "⚠️ llama-cli не смог перечислить устройства"
    
    echo ""
    echo "🔬 GFX targets in binary:"
    strings "$LLAMA_CLI" | grep -E "gfx[0-9]+" | sort -u | head -5
fi

echo ""
echo "✅ Готово! Среда восстановлена."
echo "💡 Пример рабочего запуска: см. working_launch_example.txt"
echo "💡 При проблемах: сверьтесь с rocm_symlinks.txt и gfx906_blob_manifest.txt"
REOF
chmod +x restore.sh

# ==========================================
# ИТОГ
# ==========================================
echo ""
echo "🎉 MI50 INFRASTRUCTURE SNAPSHOT v5.4 (FINAL) ЗАВЕРШЕН!"
echo "📊 Итоговый размер: $(du -sh "$BACKUP_DIR" | cut -f1)"
echo ""
echo "💎 Критические компоненты:"
[ -f rocm_runtime_backup.tar.gz ] && echo "  ✅ ROCm runtime ($(du -h rocm_runtime_backup.tar.gz | cut -f1))"
[ -f gfx906_patch.tar.gz ] && echo "  ✅ gfx906 Tensile-патчи"
[ -f gfx906_blob_manifest.txt ] && echo "  ✅ gfx906 manifest ($(wc -l < gfx906_blob_manifest.txt) blobs)"
ls llama.cpp*_build_bin.tar.gz 2>/dev/null | while read f; do echo "  ✅ Working binaries: $f"; done
echo ""
echo "🔑 Команда восстановления: sudo $BACKUP_DIR/restore.sh"
