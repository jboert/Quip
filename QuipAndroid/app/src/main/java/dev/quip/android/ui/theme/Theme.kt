package dev.quip.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

private val QuipDarkColorScheme = darkColorScheme(
    primary = AmberPrimary,
    background = Color(0xFF121216),
    surface = Color(0xFF1E1E22),
    onPrimary = Color(0xFF121216),
    onBackground = Color.White,
    onSurface = Color.White,
)

private val QuipLightColorScheme = lightColorScheme(
    primary = AmberPrimary,
    background = Color(0xFFF5F5F7),
    surface = Color.White,
    onPrimary = Color.White,
    onBackground = Color(0xFF1A1A1E),
    onSurface = Color(0xFF1A1A1E),
)

@Composable
fun QuipTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) QuipDarkColorScheme else QuipLightColorScheme
    val quipColors = if (darkTheme) DarkQuipColors else LightQuipColors

    CompositionLocalProvider(LocalQuipColors provides quipColors) {
        MaterialTheme(
            colorScheme = colorScheme,
            content = content
        )
    }
}
