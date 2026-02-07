# embeddable

- `ah` itself is a portable executable archive
- to configure and extend it(self), `ah` modifies files in its archive
- `ah` generally does not rely on external files (except maybe for authentication), though it can of course explore its environment and execute/modify things in the environment
- being embeddable is part of what makes `ah` portable: making a copy of the `ah` file carries with it everything needed to run `ah`
