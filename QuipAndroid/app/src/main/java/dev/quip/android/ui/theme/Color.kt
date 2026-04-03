package dev.quip.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

// Shared accent colors
val AmberPrimary = Color(0xFFF5A623)
val GoldGlow = Color(0xFFD4A017)

/**
 * Semantic color set that adapts to dark/light appearance.
 * Access via [LocalQuipColors] inside a [QuipTheme].
 */
@Immutable
data class QuipColors(
    val background: Color,
    val backgroundGradient: List<Color>,
    val surface: Color,
    val surfaceElevated: Color,
    val surfaceBorder: Color,
    val surfaceHeader: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val textFaint: Color,
    val buttonPrimary: Color,
    val buttonDisabled: Color,
    val divider: Color,
    val destructive: Color,
    val recording: Color,
    val dialogSurface: Color,
)

val DarkQuipColors = QuipColors(
    background = Color(0xFF121216),
    backgroundGradient = listOf(Color(0xFF101014), Color(0xFF1A1A1E), Color(0xFF121216)),
    surface = Color.White.copy(alpha = 0.08f),
    surfaceElevated = Color(0xFF141416),
    surfaceBorder = Color.White.copy(alpha = 0.03f),
    surfaceHeader = Color.White.copy(alpha = 0.06f),
    textPrimary = Color.White,
    textSecondary = Color.White.copy(alpha = 0.6f),
    textTertiary = Color.White.copy(alpha = 0.35f),
    textFaint = Color.White.copy(alpha = 0.15f),
    buttonPrimary = Color(0xFF3B82F6),
    buttonDisabled = Color.White.copy(alpha = 0.2f),
    divider = Color.White.copy(alpha = 0.08f),
    destructive = Color(0xFFE05050),
    recording = Color(0xFFE6A619),
    dialogSurface = Color(0xFF2A2A2A),
)

val LightQuipColors = QuipColors(
    background = Color(0xFFF5F5F7),
    backgroundGradient = listOf(Color(0xFFF2F2F4), Color(0xFFF8F8FA), Color(0xFFF5F5F7)),
    surface = Color.Black.copy(alpha = 0.04f),
    surfaceElevated = Color.White,
    surfaceBorder = Color.Black.copy(alpha = 0.06f),
    surfaceHeader = Color.Black.copy(alpha = 0.04f),
    textPrimary = Color(0xFF1A1A1E),
    textSecondary = Color.Black.copy(alpha = 0.55f),
    textTertiary = Color.Black.copy(alpha = 0.35f),
    textFaint = Color.Black.copy(alpha = 0.15f),
    buttonPrimary = Color(0xFF3B82F6),
    buttonDisabled = Color.Black.copy(alpha = 0.15f),
    divider = Color.Black.copy(alpha = 0.08f),
    destructive = Color(0xFFDC3545),
    recording = Color(0xFFE6A619),
    dialogSurface = Color(0xFFF0F0F2),
)

val LocalQuipColors = staticCompositionLocalOf { DarkQuipColors }
