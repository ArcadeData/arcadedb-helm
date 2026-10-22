// Prints every setting key the server image knows, one per line, prefixed with
// "KEY " so log lines the engine may print while loading stay out of the list.
// Run with the image's own JDK and classpath by ci/check-config-keys.sh (#42).
import com.arcadedb.GlobalConfiguration;

public class ListConfigKeys {
  public static void main(final String[] args) {
    for (final GlobalConfiguration setting : GlobalConfiguration.values())
      System.out.println("KEY " + setting.getKey());
  }
}
